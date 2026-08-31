-- Checklist: Resource utilization trended over time
-- Scope: SERVER
-- Scoring: 3 = collector job(s) and running collector(s), or trend table(s) with collector job(s); 2 = trend table(s), collector job(s), or running collector(s); 1 = performance counters only; 0 = no queryable trending evidence
-- NOTE: Automated evidence only; an external monitoring service may store history outside SQL Server and requires human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'No resource-utilization trending evidence found';
DECLARE @PerformanceCounterCount INT = 0;
DECLARE @TrendTableCount INT = 0;
DECLARE @CollectorJobCount INT = 0;
DECLARE @RunningCollectorCount INT = 0;

BEGIN TRY
    SELECT @PerformanceCounterCount = COUNT(*)
    FROM sys.dm_os_performance_counters;
END TRY
BEGIN CATCH
    SET @PerformanceCounterCount = 0;
END CATCH;

BEGIN TRY
    SELECT @TrendTableCount = COUNT(*)
    FROM sys.tables
    WHERE is_ms_shipped = 0
      AND (name LIKE N'%perf%' OR name LIKE N'%metric%'
           OR name LIKE N'%trend%' OR name LIKE N'%baseline%');
END TRY
BEGIN CATCH
    SET @TrendTableCount = 0;
END CATCH;

BEGIN TRY
    SELECT @CollectorJobCount = COUNT(*)
    FROM msdb.dbo.sysjobsteps
    WHERE command LIKE N'%dm[_]os%';
END TRY
BEGIN CATCH
    SET @CollectorJobCount = 0;
END CATCH;

BEGIN TRY
    SELECT @RunningCollectorCount = COUNT(*)
    FROM msdb.dbo.syscollector_collection_sets
    WHERE is_running = 1;
END TRY
BEGIN CATCH
    SET @RunningCollectorCount = 0;
END CATCH;

SET @Score = CASE
    WHEN (@CollectorJobCount > 0 AND @RunningCollectorCount > 0)
         OR (@TrendTableCount > 0 AND @CollectorJobCount > 0) THEN 3
    WHEN @TrendTableCount > 0 OR @CollectorJobCount > 0 OR @RunningCollectorCount > 0 THEN 2
    WHEN @PerformanceCounterCount > 0 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'performance counters = ', @PerformanceCounterCount,
    N'; trend tables = ', @TrendTableCount,
    N'; collector jobs = ', @CollectorJobCount,
    N'; running collectors = ', @RunningCollectorCount);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;