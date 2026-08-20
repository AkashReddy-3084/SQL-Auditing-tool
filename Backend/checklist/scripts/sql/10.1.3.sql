-- Checklist: Resource utilization trended over time
-- Scope: SERVER
-- Scoring: 3 = Agent jobs found collecting performance data; 2 = Performance counters active but no clear trending job; 1 = Minimal evidence of monitoring; 0 = No evidence found

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No evidence of resource utilization trending found';

DECLARE @JobCount INT = 0;
DECLARE @PerfCounterCount INT = 0;
DECLARE @PerfMonCount INT = 0;

-- Check for SQL Agent jobs that might be collecting performance data (looking for keywords in job names or steps)
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'msdb' AND HAS_DBACCESS('msdb') = 1)
BEGIN
    SELECT @JobCount = COUNT(*)
    FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.sysjobsteps s ON j.job_id = s.job_id
    WHERE (j.name LIKE '%perf%' OR j.name LIKE '%monitor%' OR j.name LIKE '%metric%' OR j.name LIKE '%util%')
       OR (s.command LIKE '%sys.dm_os_performance_counters%' OR s.command LIKE '%sys.dm_os_ring_buffers%');
END

-- Check if performance counters are being actively read/available
SELECT @PerfCounterCount = COUNT(*)
FROM sys.dm_os_performance_counters
WHERE counter_head_type = 1; -- System Health/Performance counters

-- Check for evidence of minimal monitoring (e.g., presence of performance-related views or tables in user databases)
-- This serves as a proxy for "Minimal evidence of monitoring" (Score 1)
IF EXISTS (SELECT 1 FROM sys.databases WHERE database_id > 4 AND state = 0)
BEGIN
    -- We use a simple check for common monitoring table names across databases via dynamic SQL to avoid hardcoding
    DECLARE @Sql NVARCHAR(MAX) = '';
    SELECT @Sql = STRING_AGG(CAST('SELECT COUNT(*) FROM ' + QUOTENAME(name) + '.sys.objects WHERE name LIKE ''%perf_log%'' OR name LIKE ''%metric_log%''' AS NVARCHAR(MAX)), ' UNION ALL ')
    FROM sys.databases WHERE database_id > 4 AND state = 0;

    IF @Sql <> ''
    BEGIN
        DECLARE @TempTable TABLE (cnt INT);
        INSERT INTO @TempTable EXEC sp_executesql @Sql;
        SELECT @PerfMonCount = SUM(cnt) FROM @TempTable;
    END
END

IF @JobCount > 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'Found ' + CAST(@JobCount AS NVARCHAR(10)) + ' SQL Agent job(s) likely collecting performance metrics.';
END
ELSE IF @PerfCounterCount > 0
BEGIN
    SET @Score = 2;
    SET @Finding = 'No specific collection jobs found, but system performance counters are active and available.';
END
ELSE IF @PerfMonCount > 0
BEGIN
    SET @Score = 1;
    SET @Finding = 'Minimal evidence of monitoring found (performance log tables detected).';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = 'No evidence of resource utilization trending or active performance counters found.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;