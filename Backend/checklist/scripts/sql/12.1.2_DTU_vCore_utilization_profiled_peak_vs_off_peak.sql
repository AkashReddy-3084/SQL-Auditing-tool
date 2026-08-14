-- Checklist: DTU/vCore utilization profiled (peak vs off-peak)
-- Scope: DATABASE
-- Scoring: 3=Query Store enabled (Read/Write) or Azure resource stats DMV has data; 2=Query Store enabled (Stale/RO) or Azure DMV exists but no data or on-prem perf counters available; 1=Basic DMVs exist but no profiling setup; 0=No relevant artifacts
-- NOTE: This script provides automated evidence. Full compliance requires human review of historical peak/off-peak trends.
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
        DECLARE @DbScore INT = 0;
        DECLARE @QSScore INT = 0;
        DECLARE @AzureScore INT = 0;
        DECLARE @OnPremScore INT = 0;
        
        -- Check Query Store state
        IF OBJECT_ID(''sys.database_query_store_options'') IS NOT NULL
            SELECT @QSScore = CASE actual_state 
                WHEN 2 THEN 3 
                WHEN 1 THEN 2 
                WHEN 3 THEN 2 
                ELSE 0 
            END FROM sys.database_query_store_options;
        
        -- Check Azure SQL DTU/vCore resource stats
        IF OBJECT_ID(''sys.dm_db_resource_stats'') IS NOT NULL
            SELECT @AzureScore = CASE 
                WHEN EXISTS(SELECT 1 FROM sys.dm_db_resource_stats WHERE avg_cpu_percent > 0) THEN 3 
                ELSE 2 
            END;
        
        -- Fallback to on-prem performance counters
        IF OBJECT_ID(''sys.dm_db_resource_stats'') IS NULL
            SELECT @OnPremScore = CASE 
                WHEN EXISTS(SELECT 1 FROM sys.dm_os_performance_counters WHERE counter_name LIKE ''CPU usage %'') THEN 2 
                ELSE 1 
            END;
        
        -- Retain the highest applicable score across all checks
        SET @DbScore = CASE WHEN @QSScore > @DbScore THEN @QSScore ELSE @DbScore END;
        SET @DbScore = CASE WHEN @AzureScore > @DbScore THEN @AzureScore ELSE @DbScore END;
        SET @DbScore = CASE WHEN @OnPremScore > @DbScore THEN @OnPremScore ELSE @DbScore END;
        
        INSERT INTO #DbResults VALUES (@DbName, @DbScore);';
        EXEC sp_executesql @Sql, N'@DbName NVARCHAR(256)', @DbName;
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