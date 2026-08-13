-- Checklist: Index maintenance (rebuild/reorganize) scheduled based on fragmentation
-- Scope: SERVER
-- Scoring: 0 = No index maintenance jobs found; 1 = Jobs found but no fragmentation threshold logic detected; 2 = Threshold logic detected in at least one job; 3 = Threshold logic detected in multiple jobs (comprehensive coverage)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @TotalJobs INT = 0;
DECLARE @ThresholdJobs INT = 0;

-- Count distinct jobs containing index maintenance commands or known framework names
SELECT @TotalJobs = COUNT(DISTINCT j.job_id)
FROM msdb.dbo.sysjobs j
INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
WHERE js.command LIKE '%ALTER INDEX%'
   OR js.command LIKE '%REBUILD%'
   OR js.command LIKE '%REORGANIZE%'
   OR js.command LIKE '%IndexOptimize%'
   OR js.command LIKE '%sp_index_optimize%'
   OR js.command LIKE '%DBCC INDEXDEFRAG%'
   OR js.command LIKE '%sys.dm_db_index_physical_stats%';

-- Count distinct jobs that also contain fragmentation threshold patterns
SELECT @ThresholdJobs = COUNT(DISTINCT j.job_id)
FROM msdb.dbo.sysjobs j
INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
WHERE (js.command LIKE '%ALTER INDEX%'
   OR js.command LIKE '%REBUILD%'
   OR js.command LIKE '%REORGANIZE%'
   OR js.command LIKE '%IndexOptimize%'
   OR js.command LIKE '%sp_index_optimize%'
   OR js.command LIKE '%DBCC INDEXDEFRAG%'
   OR js.command LIKE '%sys.dm_db_index_physical_stats%')
  AND (js.command LIKE '%fragmentation%'
     OR js.command LIKE '%@Fragmentation%'
     OR js.command LIKE '%avg_fragmentation%'
     OR js.command LIKE '%> %'
     OR js.command LIKE '%>=%'
     OR js.command LIKE '%< %'
     OR js.command LIKE '%<=%');

SET @Score = CASE
    WHEN @TotalJobs = 0 THEN 0
    WHEN @ThresholdJobs = 0 THEN 1
    WHEN @ThresholdJobs = 1 THEN 2
    WHEN @ThresholdJobs >= 2 THEN 3
    ELSE 1
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

-- NOTE: This script provides automated evidence. Full compliance requires human review.
SELECT @Result AS Result, @Score AS Score;