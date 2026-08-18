-- Checklist: Retry logic exists for transient failures
-- Scope: DATABASE
-- Scoring: 0: <10% of procedures/functions contain retry patterns. 1: 10-49% contain retry patterns. 2: 50-79% contain retry patterns. 3: >=80% contain retry patterns or no applicable objects exist.

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
    WITH ModuleAnalysis AS (
        SELECT
            o.name AS ObjectName,
            s.name AS SchemaName,
            m.definition,
            CASE
                WHEN m.definition LIKE ''%RETRY%'' OR m.definition LIKE ''%BACKOFF%'' OR m.definition LIKE ''%WAITFOR%'' OR (m.definition LIKE ''%CATCH%'' AND m.definition LIKE ''%WHILE%'')
                THEN 1
                ELSE 0
            END AS HasRetryLogic
        FROM sys.objects o
        JOIN sys.schemas s ON o.schema_id = s.schema_id
        JOIN sys.sql_modules m ON o.object_id = m.object_id
        WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'')
          AND o.is_ms_shipped = 0
    )
    SELECT
        DbName = ''' + @DbName + ''',
        DbScore = CASE
            WHEN COUNT(*) = 0 THEN 3
            WHEN CAST(SUM(HasRetryLogic) AS FLOAT) / COUNT(*) >= 0.8 THEN 3
            WHEN CAST(SUM(HasRetryLogic) AS FLOAT) / COUNT(*) >= 0.5 THEN 2
            WHEN CAST(SUM(HasRetryLogic) AS FLOAT) / COUNT(*) >= 0.1 THEN 1
            ELSE 0
        END,
        Finding = CASE
            WHEN COUNT(*) = 0 THEN ''No applicable objects found''
            WHEN CAST(SUM(HasRetryLogic) AS FLOAT) / COUNT(*) >= 0.8 THEN ''No non-compliant objects found''
            ELSE STRING_AGG(SchemaName + ''.'' + ObjectName, '', '')
        END
    FROM ModuleAnalysis;
    ';
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            WITH ModuleAnalysis AS (
                SELECT
                    o.name AS ObjectName,
                    s.name AS SchemaName,
                    m.definition,
                    CASE
                        WHEN m.definition LIKE ''%RETRY%'' OR m.definition LIKE ''%BACKOFF%'' OR m.definition LIKE ''%WAITFOR%'' OR (m.definition LIKE ''%CATCH%'' AND m.definition LIKE ''%WHILE%'')
                        THEN 1
                        ELSE 0
                    END AS HasRetryLogic
                FROM sys.objects o
                JOIN sys.schemas s ON o.schema_id = s.schema_id
                JOIN sys.sql_modules m ON o.object_id = m.object_id
                WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'')
                  AND o.is_ms_shipped = 0
            )
            SELECT
                DbName = ''' + @DbName + ''',
                DbScore = CASE
                    WHEN COUNT(*) = 0 THEN 3
                    WHEN CAST(SUM(HasRetryLogic) AS FLOAT) / COUNT(*) >= 0.8 THEN 3
                    WHEN CAST(SUM(HasRetryLogic) AS FLOAT) / COUNT(*) >= 0.5 THEN 2
                    WHEN CAST(SUM(HasRetryLogic) AS FLOAT) / COUNT(*) >= 0.1 THEN 1
                    ELSE 0
                END,
                Finding = CASE
                    WHEN COUNT(*) = 0 THEN ''No applicable objects found''
                    WHEN CAST(SUM(HasRetryLogic) AS FLOAT) / COUNT(*) >= 0.8 THEN ''No non-compliant objects found''
                    ELSE STRING_AGG(SchemaName + ''.'' + ObjectName, '', '')
                END
            FROM ModuleAnalysis;
            ';
            INSERT INTO #DbResults (DbName, DbScore, Finding)
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

SET @DatabaseQueried = (SELECT STRING_AGG(DbName, ', ') FROM #DbResults);
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''), 'No non-compliant findings found');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;