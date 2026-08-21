-- Checklist: Unique constraints on natural/business keys where appropriate
-- Scope: DATABASE
-- Scoring: 2=No tables missing unique constraints; 1=Few tables (<=5) missing; 0=Several tables (>5) missing. Capped at 2.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT;
DECLARE @Result NVARCHAR(10);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: Evaluate current database only
    DECLARE @MissingTables TABLE (TableName NVARCHAR(128));
    INSERT INTO @MissingTables
    SELECT t.name
    FROM sys.tables t
    LEFT JOIN sys.key_constraints kc ON t.object_id = kc.parent_object_id AND kc.type = 'UQ'
    WHERE kc.object_id IS NULL AND t.is_ms_shipped = 0;

    DECLARE @Count INT = (SELECT COUNT(*) FROM @MissingTables);
    SET @DatabaseQueried = DB_NAME();

    IF @Count = 0
    BEGIN
        SET @Score = 2;
        SET @Finding = 'All tables have unique constraints defined.';
    END
    ELSE
    BEGIN
        SET @Score = CASE WHEN @Count <= 5 THEN 1 ELSE 0 END;
        SET @Finding = (SELECT STRING_AGG(TableName, ', ') FROM @MissingTables);
        SET @Finding = CAST(@Count AS NVARCHAR) + ' tables missing unique constraints: ' + @Finding;
    END
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: Iterate user databases
    DECLARE @DbName NVARCHAR(256);
    DECLARE @Sql NVARCHAR(MAX);
    CREATE TABLE #DbResults (
        DbName NVARCHAR(128),
        DbScore INT,
        Finding NVARCHAR(MAX)
    );

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
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            SELECT ''' + @DbName + ''',
                   CASE WHEN COUNT(m.TableName) = 0 THEN 2
                        WHEN COUNT(m.TableName) <= 5 THEN 1
                        ELSE 0 END,
                   CASE WHEN COUNT(m.TableName) = 0 THEN ''All tables have unique constraints defined.''
                        ELSE CAST(COUNT(m.TableName) AS NVARCHAR) + '' tables missing unique constraints: '' + STRING_AGG(m.TableName, '', '') END
            FROM (SELECT t.name AS TableName FROM sys.tables t
                  LEFT JOIN sys.key_constraints kc ON t.object_id = kc.parent_object_id AND kc.type = ''UQ''
                  WHERE kc.object_id IS NULL AND t.is_ms_shipped = 0) m;
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
            WHERE Finding IS NOT NULL AND Finding <> ''
        ),
        'No non-compliant findings found'
    );

    DROP TABLE #DbResults;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;