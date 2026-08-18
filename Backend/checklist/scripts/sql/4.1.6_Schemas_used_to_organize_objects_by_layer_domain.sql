-- Checklist: Schemas used to organize objects by layer/domain
-- Scope: DATABASE
-- Scoring: 0=No user objects/failed; 1=>70% in dbo; 2=30-70% in dbo; 3=<30% in dbo

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
    -- Azure SQL Database: evaluate current DB only
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @TotalObjects INT;
    DECLARE @DboObjects INT;
    DECLARE @TopSchemas NVARCHAR(MAX);

    SELECT @TotalObjects = COUNT(*)
    FROM sys.objects
    WHERE type IN (''U'',''V'',''P'',''FN'',''IF'',''TF'')
      AND is_ms_shipped = 0;

    SELECT @DboObjects = COUNT(*)
    FROM sys.objects o
    JOIN sys.schemas s ON o.schema_id = s.schema_id
    WHERE o.type IN (''U'',''V'',''P'',''FN'',''IF'',''TF'')
      AND o.is_ms_shipped = 0
      AND s.name = ''dbo'';

    SELECT @TopSchemas = STRING_AGG(s.name + '' ('' + CAST(COUNT(*) AS NVARCHAR(10)) + '')'', '', '')
    FROM sys.objects o
    JOIN sys.schemas s ON o.schema_id = s.schema_id
    WHERE o.type IN (''U'',''V'',''P'',''FN'',''IF'',''TF'')
      AND o.is_ms_shipped = 0
    GROUP BY s.name
    ORDER BY COUNT(*) DESC;

    DECLARE @DbScore INT;
    DECLARE @DbFinding NVARCHAR(MAX);

    IF @TotalObjects = 0
    BEGIN
        SET @DbScore = 0;
        SET @DbFinding = ''No user objects found'';
    END
    ELSE
    BEGIN
        DECLARE @DboPct FLOAT = CAST(@DboObjects AS FLOAT) / @TotalObjects * 100;
        SET @DbScore = CASE
            WHEN @DboPct < 30 THEN 3
            WHEN @DboPct <= 70 THEN 2
            ELSE 1
        END;
        SET @DbFinding = CAST(@DboPct AS NVARCHAR(10)) + ''% in dbo. Top schemas: '' + ISNULL(@TopSchemas, ''None'');
    END;

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
    WHERE database_id > 4
      AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @TotalObjects INT;
            DECLARE @DboObjects INT;
            DECLARE @TopSchemas NVARCHAR(MAX);

            SELECT @TotalObjects = COUNT(*)
            FROM sys.objects
            WHERE type IN (''U'',''V'',''P'',''FN'',''IF'',''TF'')
              AND is_ms_shipped = 0;

            SELECT @DboObjects = COUNT(*)
            FROM sys.objects o
            JOIN sys.schemas s ON o.schema_id = s.schema_id
            WHERE o.type IN (''U'',''V'',''P'',''FN'',''IF'',''TF'')
              AND o.is_ms_shipped = 0
              AND s.name = ''dbo'';

            SELECT @TopSchemas = STRING_AGG(s.name + '' ('' + CAST(COUNT(*) AS NVARCHAR(10)) + '')'', '', '')
            FROM sys.objects o
            JOIN sys.schemas s ON o.schema_id = s.schema_id
            WHERE o.type IN (''U'',''V'',''P'',''FN'',''IF'',''TF'')
              AND o.is_ms_shipped = 0
            GROUP BY s.name
            ORDER BY COUNT(*) DESC;

            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            IF @TotalObjects = 0
            BEGIN
                SET @DbScore = 0;
                SET @DbFinding = ''No user objects found'';
            END
            ELSE
            BEGIN
                DECLARE @DboPct FLOAT = CAST(@DboObjects AS FLOAT) / @TotalObjects * 100;
                SET @DbScore = CASE
                    WHEN @DboPct < 30 THEN 3
                    WHEN @DboPct <= 70 THEN 2
                    ELSE 1
                END;
                SET @DbFinding = CAST(@DboPct AS NVARCHAR(10)) + ''% in dbo. Top schemas: '' + ISNULL(@TopSchemas, ''None'');
            END;

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

SET @DatabaseQueried = ISNULL(
    (SELECT STRING_AGG(DbName, ', ') FROM #DbResults),
    'None'
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