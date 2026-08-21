-- Checklist: Fragmentation-based maintenance (rebuild/reorganize) automated
-- Scope: SERVER
-- Scoring: 
-- 0: No SQL Agent jobs or maintenance plans found for index maintenance.
-- 1: Jobs/plans exist but are disabled or lack an active schedule.
-- 2: Enabled and scheduled jobs/plans found, but fragmentation thresholds require manual verification.
-- 3: Enabled and scheduled jobs/plans found with explicit fragmentation threshold checks (e.g., avg_fragmentation_in_percent, sys.dm_db_index_physical_stats).
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @EnabledJobCount INT = 0;
DECLARE @DisabledJobCount INT = 0;
DECLARE @ThresholdJobCount INT = 0;
DECLARE @JobNames NVARCHAR(MAX) = '';
DECLARE @ThresholdJobNames NVARCHAR(MAX) = '';

-- 1. Check for enabled and scheduled jobs containing index maintenance commands
SELECT @EnabledJobCount = COUNT(*)
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
WHERE j.enabled = 1
  AND j.has_schedule = 1
  AND (
    js.command LIKE '%ALTER INDEX%'
    OR js.command LIKE '%REBUILD%'
    OR js.command LIKE '%REORGANIZE%'
    OR js.command LIKE '%IndexOptimize%'
    OR js.command LIKE '%sp_index_optimize%'
  );

SELECT @JobNames = STRING_AGG(DISTINCT j.name, ', ')
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
WHERE j.enabled = 1
  AND j.has_schedule = 1
  AND (
    js.command LIKE '%ALTER INDEX%'
    OR js.command LIKE '%REBUILD%'
    OR js.command LIKE '%REORGANIZE%'
    OR js.command LIKE '%IndexOptimize%'
    OR js.command LIKE '%sp_index_optimize%'
  );

-- 2. Check if any of those jobs explicitly reference fragmentation thresholds
SELECT @ThresholdJobCount = COUNT(*)
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
WHERE j.enabled = 1
  AND j.has_schedule = 1
  AND (
    js.command LIKE '%ALTER INDEX%'
    OR js.command LIKE '%REBUILD%'
    OR js.command LIKE '%REORGANIZE%'
    OR js.command LIKE '%IndexOptimize%'
    OR js.command LIKE '%sp_index_optimize%'
  )
  AND (
    js.command LIKE '%avg_fragmentation_in_percent%'
    OR js.command LIKE '%sys.dm_db_index_physical_stats%'
    OR js.command LIKE '%fragmentation%'
  );

SELECT @ThresholdJobNames = STRING_AGG(DISTINCT j.name, ', ')
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
WHERE j.enabled = 1
  AND j.has_schedule = 1
  AND (
    js.command LIKE '%ALTER INDEX%'
    OR js.command LIKE '%REBUILD%'
    OR js.command LIKE '%REORGANIZE%'
    OR js.command LIKE '%IndexOptimize%'
    OR js.command LIKE '%sp_index_optimize%'
  )
  AND (
    js.command LIKE '%avg_fragmentation_in_percent%'
    OR js.command LIKE '%sys.dm_db_index_physical_stats%'
    OR js.command LIKE '%fragmentation%'
  );

-- 3. Check for disabled or unscheduled jobs
SELECT @DisabledJobCount = COUNT(*)
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
WHERE (j.enabled = 0 OR j.has_schedule = 0)
  AND (
    js.command LIKE '%ALTER INDEX%'
    OR js.command LIKE '%REBUILD%'
    OR js.command LIKE '%REORGANIZE%'
    OR js.command LIKE '%IndexOptimize%'
    OR js.command LIKE '%sp_index_optimize%'
  );

-- Assign Score based on evidence hierarchy
IF @ThresholdJobCount > 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'Found ' + CAST(@ThresholdJobCount AS NVARCHAR(10)) + ' enabled/scheduled job(s) with explicit fragmentation threshold checks: ' + ISNULL(@ThresholdJobNames, 'None');
END
ELSE IF @EnabledJobCount > 0
BEGIN
    SET @Score = 2;
    SET @Finding = 'Found ' + CAST(@EnabledJobCount AS NVARCHAR(10)) + ' enabled/scheduled job(s) for index maintenance, but fragmentation thresholds require manual verification: ' + ISNULL(@JobNames, 'None');
END
ELSE IF @DisabledJobCount > 0
BEGIN
    SET @Score = 1;
    SET @Finding = 'Found ' + CAST(@DisabledJobCount AS NVARCHAR(10)) + ' job(s) for index maintenance, but they are disabled or lack a schedule.';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = 'No automated SQL Agent jobs or maintenance plans found for index fragmentation maintenance.';
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;