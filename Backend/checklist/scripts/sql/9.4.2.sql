-- Checklist: Load completion SLAs set and monitored
-- Scope: SERVER
-- Scoring: 3 = ETL/load jobs are enabled, run on an enabled schedule, carry a notification hook and have measurable run durations in history; 2 = scheduled load jobs with run-duration history but no notification hook, or platform-managed on Azure SQL Database; 1 = load jobs identified but not scheduled or without run history; 0 = no ETL/load jobs identified

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Load job scheduling and run-duration evidence was unavailable';
DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Cut INT = CONVERT(INT, CONVERT(CHAR(8), DATEADD(DAY, -30, GETDATE()), 112));
DECLARE @Sql NVARCHAR(MAX);
DECLARE @LoadJobs INT = 0;
DECLARE @Scheduled INT = 0;
DECLARE @Monitored INT = 0;
DECLARE @RecentRuns INT = 0;
DECLARE @MaxSeconds INT = 0;
DECLARE @Names NVARCHAR(400) = 'none';
DECLARE @ReadNote NVARCHAR(300) = '';
DECLARE @M TABLE (K NVARCHAR(40), V INT NULL, T NVARCHAR(400) NULL);

IF @Edition = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database (EngineEdition 5): SQL Server Agent does not exist, so load orchestration and its completion SLA are owned by an external scheduler (Data Factory, Elastic Jobs or Logic Apps) and cannot be evidenced from inside the engine.';
END
ELSE
BEGIN
    SET @Sql = N'
WITH LoadJobs AS (
    SELECT j.job_id, j.name, j.notify_level_email, j.notify_level_eventlog
    FROM msdb.dbo.sysjobs AS j
    LEFT JOIN msdb.dbo.syscategories AS c ON c.category_id = j.category_id
    WHERE j.enabled = 1
      AND (j.name LIKE ''%etl%'' OR j.name LIKE ''%load%'' OR j.name LIKE ''%import%''
           OR j.name LIKE ''%ingest%'' OR j.name LIKE ''%extract%'' OR j.name LIKE ''%staging%''
           OR c.name LIKE ''%etl%'' OR c.name LIKE ''%load%'' OR c.name LIKE ''%data%'')
)
SELECT ''LoadJobs'', COUNT(*), CONVERT(NVARCHAR(400), NULL) FROM LoadJobs
UNION ALL SELECT ''Scheduled'', COUNT(DISTINCT lj.job_id), NULL FROM LoadJobs AS lj INNER JOIN msdb.dbo.sysjobschedules AS js ON js.job_id = lj.job_id INNER JOIN msdb.dbo.sysschedules AS s ON s.schedule_id = js.schedule_id AND s.enabled = 1
UNION ALL SELECT ''Monitored'', COUNT(*), NULL FROM LoadJobs WHERE notify_level_email > 0 OR notify_level_eventlog > 0
UNION ALL SELECT ''RecentRuns'', COUNT(*), NULL FROM LoadJobs AS lj INNER JOIN msdb.dbo.sysjobhistory AS h ON h.job_id = lj.job_id AND h.step_id = 0 WHERE h.run_date >= @cut
UNION ALL SELECT ''MaxSeconds'', ISNULL(MAX((h.run_duration / 10000) * 3600 + ((h.run_duration / 100) % 100) * 60 + (h.run_duration % 100)), 0), NULL FROM LoadJobs AS lj INNER JOIN msdb.dbo.sysjobhistory AS h ON h.job_id = lj.job_id AND h.step_id = 0 WHERE h.run_date >= @cut
UNION ALL SELECT ''Names'', NULL, ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(200), x.name), '', '') FROM (SELECT TOP (5) name FROM LoadJobs ORDER BY name) AS x), ''none'')';

    BEGIN TRY
        INSERT INTO @M (K, V, T) EXEC sp_executesql @Sql, N'@cut INT', @cut = @Cut;
    END TRY
    BEGIN CATCH
        SET @ReadNote = ' One or more SQL Agent sources could not be read: ' + LEFT(ISNULL(ERROR_MESSAGE(), ''), 150) + '.';
    END CATCH;

    SELECT @LoadJobs = ISNULL(MAX(CASE WHEN K = 'LoadJobs' THEN V END), 0),
           @Scheduled = ISNULL(MAX(CASE WHEN K = 'Scheduled' THEN V END), 0),
           @Monitored = ISNULL(MAX(CASE WHEN K = 'Monitored' THEN V END), 0),
           @RecentRuns = ISNULL(MAX(CASE WHEN K = 'RecentRuns' THEN V END), 0),
           @MaxSeconds = ISNULL(MAX(CASE WHEN K = 'MaxSeconds' THEN V END), 0),
           @Names = ISNULL(MAX(CASE WHEN K = 'Names' THEN T END), 'none')
    FROM @M;

    SET @Score = CASE
        WHEN @LoadJobs > 0 AND @Scheduled > 0 AND @Monitored > 0 AND @RecentRuns > 0 THEN 3
        WHEN @LoadJobs > 0 AND @Scheduled > 0 AND @RecentRuns > 0 THEN 2
        WHEN @LoadJobs > 0 THEN 1
        ELSE 0
    END;

    SET @Finding = CONCAT(
        'Enabled ETL/load jobs = ', @LoadJobs, ' (', @Names, ')',
        '; on an enabled schedule = ', @Scheduled,
        '; with a completion notification hook = ', @Monitored,
        '; completed runs recorded in the last 30 days = ', @RecentRuns,
        '; longest recorded run = ', @MaxSeconds, ' second(s).',
        CASE WHEN @LoadJobs = 0 THEN ' No enabled job name or category identifies a load or ETL workload, so no load completion time can be measured against an SLA.' ELSE '' END,
        @ReadNote);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
