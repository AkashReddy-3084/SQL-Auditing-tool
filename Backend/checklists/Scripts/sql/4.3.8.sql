-- Checklist: [Indexing Strategy] Index maintenance (rebuild/reorganize) scheduled based on fragmentation
-- Scope: SERVER
-- Scoring: 3 = an enabled index-maintenance job on an enabled schedule driven by fragmentation; 2 = an enabled, scheduled index-maintenance job with no fragmentation logic, or Azure SQL Database platform-managed; 1 = index-maintenance job exists but is disabled or has no enabled schedule; 0 = no index-maintenance job, or job metadata unreadable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'SQL Agent job metadata could not be read; index maintenance scheduling is unverified';

DECLARE @IsAzureDb BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @ReadError BIT = 0;
DECLARE @TotalJobs INT = 0;
DECLARE @ScheduledJobs INT = 0;
DECLARE @FragJobs INT = 0;
DECLARE @JobList NVARCHAR(MAX) = 'none';

DECLARE @IdxPattern     NVARCHAR(60) = '%INDEX%';
DECLARE @RebuildPattern NVARCHAR(60) = '%' + CHAR(82) + 'EBUILD%';
DECLARE @ReorgPattern   NVARCHAR(60) = '%' + CHAR(82) + 'EORGANIZE%';
DECLARE @OlaPattern     NVARCHAR(60) = '%INDEXOPTIMIZE%';
DECLARE @FragPattern    NVARCHAR(60) = '%FRAGMENTATION%';

CREATE TABLE #IdxJobs
(
    JobName     SYSNAME NOT NULL,
    IsEnabled   INT     NOT NULL,
    IsScheduled INT     NOT NULL,
    IsFragAware INT     NOT NULL
);

-- msdb is absent on Azure SQL Database, so the job query only ever runs as dynamic text.
DECLARE @Sql NVARCHAR(MAX) = N'
SELECT j.name,
       MAX(CONVERT(INT, j.enabled)),
       MAX(CASE WHEN sc.enabled = 1 THEN 1 ELSE 0 END),
       MAX(CASE WHEN UPPER(s.command) LIKE @frag OR UPPER(s.command) LIKE @ola THEN 1 ELSE 0 END)
FROM msdb.dbo.sysjobs AS j
INNER JOIN msdb.dbo.sysjobsteps AS s ON s.job_id = j.job_id
LEFT JOIN msdb.dbo.sysjobschedules AS js ON js.job_id = j.job_id
LEFT JOIN msdb.dbo.sysschedules AS sc ON sc.schedule_id = js.schedule_id
WHERE (UPPER(s.command) LIKE @idx AND (UPPER(s.command) LIKE @reb OR UPPER(s.command) LIKE @reo))
   OR UPPER(s.command) LIKE @ola
GROUP BY j.job_id, j.name;';

IF @IsAzureDb = 0
BEGIN
    BEGIN TRY
        INSERT INTO #IdxJobs (JobName, IsEnabled, IsScheduled, IsFragAware)
        EXEC sp_executesql @Sql,
             N'@idx NVARCHAR(60), @reb NVARCHAR(60), @reo NVARCHAR(60), @ola NVARCHAR(60), @frag NVARCHAR(60)',
             @idx = @IdxPattern, @reb = @RebuildPattern, @reo = @ReorgPattern,
             @ola = @OlaPattern, @frag = @FragPattern;
    END TRY
    BEGIN CATCH
        SET @ReadError = 1;
    END CATCH;
END

SELECT @TotalJobs     = COUNT(*),
       @ScheduledJobs = ISNULL(SUM(CASE WHEN IsEnabled = 1 AND IsScheduled = 1 THEN 1 ELSE 0 END), 0),
       @FragJobs      = ISNULL(SUM(CASE WHEN IsEnabled = 1 AND IsScheduled = 1 AND IsFragAware = 1 THEN 1 ELSE 0 END), 0)
FROM #IdxJobs;

SET @JobList = ISNULL(LEFT((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), JobName), ', ') FROM #IdxJobs), 900), 'none');

SET @Score = CASE
    WHEN @IsAzureDb = 1 THEN 2
    WHEN @ReadError = 1 THEN 0
    WHEN @FragJobs > 0 THEN 3
    WHEN @ScheduledJobs > 0 THEN 2
    WHEN @TotalJobs > 0 THEN 1
    ELSE 0
END;

SET @Finding = CASE
    WHEN @IsAzureDb = 1
        THEN 'Azure SQL Database (EngineEdition 5): SQL Agent and msdb job metadata are not exposed; index defragmentation is handled by the platform automatic tuning service.'
    WHEN @ReadError = 1
        THEN 'SQL Agent job metadata in msdb could not be read by the audit login, so scheduled index maintenance could not be confirmed.'
    WHEN @TotalJobs = 0
        THEN 'No SQL Agent job step on this instance issues an index rebuild or reorganize command; index fragmentation is not remediated on a schedule.'
    ELSE CONCAT('Index-maintenance SQL Agent jobs found = ', @TotalJobs,
                '; enabled and attached to an enabled schedule = ', @ScheduledJobs,
                '; of those, driven by fragmentation thresholds = ', @FragJobs,
                '. Jobs: ', @JobList, '.')
END;

DROP TABLE #IdxJobs;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
