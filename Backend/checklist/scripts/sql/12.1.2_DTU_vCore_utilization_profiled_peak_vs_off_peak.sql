-- Checklist: DTU/vCore utilization profiled (peak vs off-peak)
-- Scope: SERVER
-- Scoring: 0: No utilization data available. 1: Minimal/intermittent data. 2: Recent utilization metrics available (proxy evidence). 3: Full historical profiling (requires manual/external tools). Automated checks cap at 2.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @MaxCpu DECIMAL(5,2);
DECLARE @AvgCpu DECIMAL(5,2);

SET @DatabaseQueried = 'master';

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database
    BEGIN TRY
        SELECT @MaxCpu = MAX(max_cpu_percent), @AvgCpu = AVG(avg_cpu_percent)
        FROM sys.dm_db_resource_stats;
    END TRY
    BEGIN CATCH
        SET @MaxCpu = NULL;
        SET @AvgCpu = NULL;
    END CATCH;
    
    SET @Score = CASE 
        WHEN @MaxCpu IS NULL THEN 0
        WHEN @MaxCpu < 10 THEN 1
        ELSE 2
    END;
    SET @Finding = 'Azure SQL DB utilization (last 1h): Avg CPU = ' + ISNULL(CAST(@AvgCpu AS NVARCHAR), 'N/A') + '%, Peak CPU = ' + ISNULL(CAST(@MaxCpu AS NVARCHAR), 'N/A') + '%. Automated proxy evidence provided.';
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI
    BEGIN TRY
        SELECT @MaxCpu = MAX(cntr_value), @AvgCpu = AVG(cntr_value)
        FROM sys.dm_os_performance_counters
        WHERE object_name LIKE '%Resource Pool Stats%'
          AND counter_name = 'CPU usage %'
          AND instance_name = 'default';
    END TRY
    BEGIN CATCH
        SET @MaxCpu = NULL;
        SET @AvgCpu = NULL;
    END CATCH;
    
    SET @Score = CASE 
        WHEN @MaxCpu IS NULL THEN 0
        WHEN @MaxCpu < 10 THEN 1
        ELSE 2
    END;
    SET @Finding = 'SQL Server/MI vCore utilization (current snapshot): Avg CPU = ' + ISNULL(CAST(@AvgCpu AS NVARCHAR), 'N/A') + '%, Peak CPU = ' + ISNULL(CAST(@MaxCpu AS NVARCHAR), 'N/A') + '%. Automated proxy evidence provided.';
END

-- NOTE: This script provides automated evidence. Full compliance requires human review.

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;