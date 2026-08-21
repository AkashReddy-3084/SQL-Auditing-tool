-- Checklist: Baselines captured for comparison over time
-- Scope: DATABASE
-- Scoring: 3=Baselines found; 2=Query Store enabled, no baselines (or v<2022); 1=Query Store disabled; 0=Offline/failed

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
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
    -- Azure SQL Database: evaluate current connected database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @QsState INT;
    DECLARE @BaselineCount INT = 0;
    DECLARE @DbScore INT = 0;
    DECLARE @DbFinding NVARCHAR(MAX) = '''';
    DECLARE @Version INT = CAST(SERVERPROPERTY(''ProductMajorVersion'') AS INT);

    SELECT @QsState = actual_state FROM sys.database_query_store_options;

    IF @QsState IN (1, 2)
    BEGIN
        IF OBJECT_ID(''sys.query_store_plan_attribute'') IS NOT NULL
        BEGIN
            SELECT @BaselineCount = COUNT(*) FROM sys.query_store_plan_attribute WHERE attribute_name = ''baseline'';
        END

        IF @BaselineCount > 0
        BEGIN
            SET @DbScore = 3;
            SET @DbFinding = ''Baseline(s) captured ('' + CAST(@BaselineCount AS NVARCHAR) + '')'';
        END
        ELSE
        BEGIN
            IF @Version < 16
            BEGIN
                SET @DbScore = 2;
                SET @DbFinding = ''Query Store enabled, but baseline feature not available in this version'';
            END
            ELSE
            BEGIN
                SET @DbScore = 2;
                SET @DbFinding = ''Query Store enabled, but no baselines captured'';
            END
        END
    END
    ELSE
    BEGIN
        SET @DbScore = 1;
        SET @DbFinding = ''Query Store disabled'';
    END

    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate all online user databases
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
            DECLARE @QsState INT;
            DECLARE @BaselineCount INT = 0;
            DECLARE @DbScore INT = 0;
            DECLARE @DbFinding NVARCHAR(MAX) = '''';
            DECLARE @Version INT = CAST(SERVERPROPERTY(''ProductMajorVersion'') AS INT);

            SELECT @QsState = actual_state FROM sys.database_query_store_options;

            IF @QsState IN (1, 2)
            BEGIN
                IF OBJECT_ID(''sys.query_store_plan_attribute'') IS NOT NULL
                BEGIN
                    SELECT @BaselineCount = COUNT(*) FROM sys.query_store_plan_attribute WHERE attribute_name = ''baseline'';
                END

                IF @BaselineCount > 0
                BEGIN
                    SET @DbScore = 3;
                    SET @DbFinding = ''Baseline(s) captured ('' + CAST(@BaselineCount AS NVARCHAR) + '')'';
                END
                ELSE
                BEGIN
                    IF @Version < 16
                    BEGIN
                        SET @DbScore = 2;
                        SET @DbFinding = ''Query Store enabled, but baseline feature not available in this version'';
                    END
                    ELSE
                    BEGIN
                        SET @DbScore = 2;
                        SET @DbFinding = ''Query Store enabled, but no baselines captured'';
                    END
                END
            END
            ELSE
            BEGIN
                SET @DbScore = 1;
                SET @DbFinding = ''Query Store disabled'';
            END

            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @DbFinding);
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