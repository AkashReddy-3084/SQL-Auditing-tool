-- Checklist: Index maintenance (rebuild/reorganize) scheduled based on fragmentation
-- Scope: SERVER
-- Scoring: 0: No index maintenance jobs found. 1: Jobs exist but are not scheduled. 2: Scheduled jobs found but lack explicit fragmentation-aware logic in job steps. 3: Scheduled jobs contain explicit fragmentation thresholds or use recognized fragmentation-aware scripts.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @JobCount INT = 0;
DECLARE @ScheduledCount INT = 0;
DECLARE @FragAwareCount INT = 0;
DECLARE @JobNames NVARCHAR(MAX) = '';
DECLARE @ScheduledJobNames NVARCHAR(MAX) = '';
DECLARE @FragAwareJobNames NVARCHAR(MAX) = '';

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Score = 1;
    SET @Finding = 'Azure SQL Database does not support SQL Server Agent. Index maintenance is managed by the platform or external automation.';
END
ELSE
BEGIN
    SELECT 
        j.job_id,
        j.name AS JobName,
        MAX(CASE WHEN s.enabled = 1 THEN 1 ELSE 0 END) AS IsScheduled,
        MAX(CASE WHEN s.enabled = 1 AND (js.command LIKE '%Fragmentation%' OR js.command LIKE '%avg_fragmentation%' OR js.command LIKE '%@Fragmentation%' OR js.command LIKE '%IndexOptimize%' OR js.command LIKE '%sys.dm_db_index_physical_stats%') THEN 1 ELSE 0 END) AS IsFragAware
    INTO #IndexJobs
    FROM msdb.dbo.sysjobs j
    INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
    LEFT JOIN msdb.dbo.sysjobschedules jsch ON j.job_id = jsch.job_id
    LEFT JOIN msdb.dbo.sysschedules s ON jsch.schedule_id = s.schedule_id
    WHERE js.command LIKE '%ALTER INDEX%' 
       OR js.command LIKE '%REBUILD%' 
       OR js.command LIKE '%REORGANIZE%' 
       OR js.command LIKE '%IndexOptimize%'
       OR js.command LIKE '%DBCC INDEXDEFRAG%'
    GROUP BY j.job_id, j.name;

    SELECT @JobCount = COUNT(*),
           @JobNames = STRING_AGG(JobName, ', ') WITHIN GROUP (ORDER BY JobName)
    FROM #IndexJobs;

    SELECT @ScheduledCount = COUNT(*),
           @ScheduledJobNames = STRING_AGG(JobName, ', ') WITHIN GROUP (ORDER BY JobName)
    FROM #IndexJobs WHERE IsScheduled = 1;

    SELECT @FragAwareCount = COUNT(*),
           @FragAwareJobNames = STRING_AGG(JobName, ', ') WITHIN GROUP (ORDER BY JobName)
    FROM #IndexJobs WHERE IsFragAware = 1;

    IF @JobCount = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No index maintenance jobs found in SQL Server Agent.';
    END
    ELSE IF @ScheduledCount = 0
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Index maintenance jobs found but none are scheduled: ' + ISNULL(@JobNames, 'None');
    END
    ELSE IF @FragAwareCount = 0
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Scheduled index maintenance jobs found, but none explicitly reference fragmentation thresholds or dynamic evaluation: ' + ISNULL(@ScheduledJobNames, 'None');
    END
    ELSE
    BEGIN
        SET @Score = 3;
        SET @Finding = 'Scheduled index maintenance jobs with fragmentation-aware logic found: ' + ISNULL(@FragAwareJobNames, 'None');
    END;

    DROP TABLE #IndexJobs;
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;