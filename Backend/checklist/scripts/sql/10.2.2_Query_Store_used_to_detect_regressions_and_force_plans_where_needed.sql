-- Checklist: Query Store used to detect regressions and force plans where needed
-- Scope: DATABASE
-- Scoring: 0=Disabled, 1=Enabled but no usage evidence, 2=Enabled with forced plans or runtime stats, 3=Enabled with forced plans and active runtime stats
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @QsState INT = 0;
        DECLARE @ForcedCount INT = 0;
        DECLARE @RuntimeCount INT = 0;

        IF OBJECT_ID('sys.database_query_store_options') IS NOT NULL
        BEGIN
            SELECT @QsState = actual_state FROM sys.database_query_store_options;
            IF @QsState = 2 -- Read/Write (Enabled)
            BEGIN
                SELECT @ForcedCount = COUNT(*) FROM sys.query_store_plan WHERE is_forced_plan = 1;
                SELECT @RuntimeCount = COUNT(*) FROM sys.query_store_runtime_stats;
            END
        END

        INSERT INTO #DbResults (DbName, DbScore)
        SELECT ''' + @DbName + ''',
               CASE
                   WHEN @QsState <> 2 THEN 0
                   WHEN @ForcedCount > 0 AND @RuntimeCount > 0 THEN 3
                   WHEN @ForcedCount > 0 OR @RuntimeCount > 0 THEN 2
                   ELSE 1
               END;
        ';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Aggregate: worst-case score across all databases
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;