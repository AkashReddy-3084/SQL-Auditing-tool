-- Checklist: Historical SLA compliance tracked and reported
-- Scope: SERVER
-- Scoring: 3 = 30 or more days of job outcome history retained, bounded by a history-retention job and consumed by an SLA/reporting job; 2 = 30 or more days of history retained, or platform-managed on Azure SQL Database; 1 = some history retained but a shorter window with no retention or reporting job; 0 = no run history retained

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Historical run-outcome evidence was unavailable';
DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Sql NVARCHAR(MAX);
DECLARE @HistoryRows INT = 0;
DECLARE @DistinctJobs INT = 0;
DECLARE @OldestRun INT = 0;
DECLARE @FailedRuns INT = 0;
DECLARE @CleanupJobs INT = 0;
DECLARE @ReportingJobs INT = 0;
DECLARE @RetentionDays INT = 0;
DECLARE @OldestText NVARCHAR(20) = 'none';
DECLARE @ReadNote NVARCHAR(300) = '';
DECLARE @M TABLE (K NVARCHAR(40), V INT NULL);

IF @Edition = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database (EngineEdition 5): SQL Server Agent and msdb job history do not exist, so historical SLA compliance is retained and reported by the platform through Azure Monitor and diagnostic settings outside the engine.';
END
ELSE
BEGIN
    SET @Sql = N'
SELECT ''HistoryRows'', COUNT(*) FROM msdb.dbo.sysjobhistory WHERE step_id = 0
UNION ALL SELECT ''DistinctJobs'', COUNT(DISTINCT job_id) FROM msdb.dbo.sysjobhistory WHERE step_id = 0
UNION ALL SELECT ''OldestRun'', ISNULL(MIN(run_date), 0) FROM msdb.dbo.sysjobhistory WHERE step_id = 0 AND run_date > 0
UNION ALL SELECT ''FailedRuns'', COUNT(*) FROM msdb.dbo.sysjobhistory WHERE step_id = 0 AND run_status <> 1
UNION ALL SELECT ''CleanupJobs'', COUNT(*) FROM msdb.dbo.sysjobs AS j WHERE j.enabled = 1 AND (j.name LIKE ''%history%clean%'' OR j.name LIKE ''%clean%history%'' OR EXISTS (SELECT 1 FROM msdb.dbo.sysjobsteps AS s WHERE s.job_id = j.job_id AND (s.command LIKE ''%purge_jobhistory%'' OR s.command LIKE ''%delete_backuphistory%'' OR s.command LIKE ''%HistoryCleanup%'')))
UNION ALL SELECT ''ReportingJobs'', COUNT(*) FROM msdb.dbo.sysjobs AS j WHERE j.enabled = 1 AND (j.name LIKE ''%sla%'' OR j.name LIKE ''%report%'' OR EXISTS (SELECT 1 FROM msdb.dbo.sysjobsteps AS s WHERE s.job_id = j.job_id AND s.command LIKE ''%sysjobhistory%''))';

    BEGIN TRY
        INSERT INTO @M (K, V) EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        SET @ReadNote = ' One or more job history sources could not be read: ' + LEFT(ISNULL(ERROR_MESSAGE(), ''), 150) + '.';
    END CATCH;

    SELECT @HistoryRows = ISNULL(MAX(CASE WHEN K = 'HistoryRows' THEN V END), 0),
           @DistinctJobs = ISNULL(MAX(CASE WHEN K = 'DistinctJobs' THEN V END), 0),
           @OldestRun = ISNULL(MAX(CASE WHEN K = 'OldestRun' THEN V END), 0),
           @FailedRuns = ISNULL(MAX(CASE WHEN K = 'FailedRuns' THEN V END), 0),
           @CleanupJobs = ISNULL(MAX(CASE WHEN K = 'CleanupJobs' THEN V END), 0),
           @ReportingJobs = ISNULL(MAX(CASE WHEN K = 'ReportingJobs' THEN V END), 0)
    FROM @M;

    SET @RetentionDays = ISNULL(DATEDIFF(DAY, TRY_CONVERT(DATE, CONVERT(CHAR(8), @OldestRun), 112), GETDATE()), 0);
    SET @OldestText = ISNULL(CONVERT(NVARCHAR(20), TRY_CONVERT(DATE, CONVERT(CHAR(8), @OldestRun), 112), 23), 'none');

    SET @Score = CASE
        WHEN @HistoryRows > 0 AND @RetentionDays >= 30 AND @CleanupJobs > 0 AND @ReportingJobs > 0 THEN 3
        WHEN @HistoryRows > 0 AND @RetentionDays >= 30 THEN 2
        WHEN @HistoryRows > 0 THEN 1
        ELSE 0
    END;

    SET @Finding = CONCAT(
        'Retained job outcome rows = ', @HistoryRows, ' across ', @DistinctJobs, ' job(s), ',
        @FailedRuns, ' of them failed outcomes; oldest retained run = ', @OldestText,
        ' (', @RetentionDays, ' day window)',
        '; enabled history retention jobs = ', @CleanupJobs,
        '; enabled jobs that read or report on that history = ', @ReportingJobs, '.',
        CASE WHEN @HistoryRows = 0 THEN ' No run outcome history is retained, so no historical SLA compliance can be reported.' ELSE '' END,
        @ReadNote);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;