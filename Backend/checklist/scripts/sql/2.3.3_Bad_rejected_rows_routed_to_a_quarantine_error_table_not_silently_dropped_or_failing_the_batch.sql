-- Checklist: Bad/rejected rows routed to a quarantine/error table (not silently dropped or failing the batch)
-- Scope: DATABASE
-- Scoring: 0=No error tables found; 1=1-2 error tables found, no proc references; 2=3+ error tables found, 1+ proc references; 3=5+ error tables found, 3+ proc references
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @ErrorTables TABLE (SchemaName NVARCHAR(128), TableName NVARCHAR(128));
    DECLARE @ProcRefs INT = 0;

    INSERT INTO @ErrorTables
    SELECT s.name, t.name
    FROM sys.tables t
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE t.name LIKE ''%error%'' OR t.name LIKE ''%reject%'' OR t.name LIKE ''%quarantine%'' OR t.name LIKE ''%bad%''
       OR s.name LIKE ''%error%'' OR s.name LIKE ''%reject%'' OR s.name LIKE ''%quarantine%'' OR s.name LIKE ''%staging%'';

    SELECT @ProcRefs = COUNT(*)
    FROM sys.procedures p
    WHERE OBJECT_DEFINITION(p.object_id) LIKE ''%INSERT INTO%''
      AND EXISTS (
          SELECT 1 FROM @ErrorTables et
          WHERE OBJECT_DEFINITION(p.object_id) LIKE ''%'' + et.TableName + ''%''
      );

    DECLARE @TableCount INT = (SELECT COUNT(*) FROM @ErrorTables);
    DECLARE @DbScore INT = 0;
    DECLARE @DbFinding NVARCHAR(MAX) = ''Error tables: '' + CAST(@TableCount AS NVARCHAR(10)) + ''; Referencing procedures: '' + CAST(@ProcRefs AS NVARCHAR(10));

    IF @TableCount = 0 SET @DbScore = 0;
    ELSE IF @TableCount <= 2 AND @ProcRefs = 0 SET @DbScore = 1;
    ELSE IF @TableCount >= 3 AND @ProcRefs >= 1 SET @DbScore = 2;
    ELSE IF @TableCount >= 5 AND @ProcRefs >= 3 SET @DbScore = 3;

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @ErrorTables TABLE (SchemaName NVARCHAR(128), TableName NVARCHAR(128));
            DECLARE @ProcRefs INT = 0;

            INSERT INTO @ErrorTables
            SELECT s.name, t.name
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE t.name LIKE ''%error%'' OR t.name LIKE ''%reject%'' OR t.name LIKE ''%quarantine%'' OR t.name LIKE ''%bad%''
               OR s.name LIKE ''%error%'' OR s.name LIKE ''%reject%'' OR s.name LIKE ''%quarantine%'' OR s.name LIKE ''%staging%'';

            SELECT @ProcRefs = COUNT(*)
            FROM sys.procedures p
            WHERE OBJECT_DEFINITION(p.object_id) LIKE ''%INSERT INTO%''
              AND EXISTS (
                  SELECT 1 FROM @ErrorTables et
                  WHERE OBJECT_DEFINITION(p.object_id) LIKE ''%'' + et.TableName + ''%''
              );

            DECLARE @TableCount INT = (SELECT COUNT(*) FROM @ErrorTables);
            DECLARE @DbScore INT = 0;
            DECLARE @DbFinding NVARCHAR(MAX) = ''Error tables: '' + CAST(@TableCount AS NVARCHAR(10)) + ''; Referencing procedures: '' + CAST(@ProcRefs AS NVARCHAR(10));

            IF @TableCount = 0 SET @DbScore = 0;
            ELSE IF @TableCount <= 2 AND @ProcRefs = 0 SET @DbScore = 1;
            ELSE IF @TableCount >= 3 AND @ProcRefs >= 1 SET @DbScore = 2;
            ELSE IF @TableCount >= 5 AND @ProcRefs >= 3 SET @DbScore = 3;

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
            ';
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Database evaluation failed');
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = (
    SELECT STRING_AGG(DbName, ', ')
    FROM #DbResults
);

SET @Score = ISNULL(
    (SELECT MIN(DbScore) FROM #DbResults),
    0
);

SET @Finding = ISNULL(
    (
        SELECT STRING_AGG(DbName + ': ' + Finding, '; ')
        FROM #DbResults
        WHERE Finding IS NOT NULL
          AND Finding <> ''
    ),
    'No non-compliant findings found'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;