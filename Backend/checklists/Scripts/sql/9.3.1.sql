/* Checklist 9.3.1 - Consistency checks (DBCC CHECKDB) scheduled and monitored (SQL Server / Azure SQL MI)
   Scope: SERVER. Strictly read-only.
   Evidence: an enabled SQL Agent job that runs DBCC CHECK* (or Ola Hallengren DatabaseIntegrityCheck),
   bound to an enabled schedule, with a recent successful outcome and failure notification configured. */
SET NOCOUNT ON;

DECLARE @Result NVARCHAR(50) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(256) = ISNULL(DB_NAME(), N'None');
DECLARE @Finding NVARCHAR(4000) = N'No evidence collected.';

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Jobs INT = 0;
DECLARE @EnabledJobs INT = 0;
DECLARE @ScheduledJobs INT = 0;
DECLARE @RecentJobs INT = 0;
DECLARE @NotifiedJobs INT = 0;
DECLARE @LastGood NVARCHAR(30) = NULL;
DECLARE @sql NVARCHAR(MAX);

IF @EngineEdition = 5
BEGIN
    SET @Score = 3;
    SET @Finding = N'Azure SQL Database (EngineEdition 5) detected. Database consistency checking is performed automatically by the platform and DBCC CHECKDB scheduling is not a customer responsibility; this checklist item applies to SQL Server and Azure SQL Managed Instance only.';
END
ELSE
BEGIN
    BEGIN TRY
        SET @sql = N'
SELECT @pJobs = COUNT(*),
       @pEnabled = SUM(CASE WHEN j.enabled = 1 THEN 1 ELSE 0 END),
       @pScheduled = SUM(CASE WHEN j.enabled = 1 AND x.SchedCount > 0 THEN 1 ELSE 0 END),
       @pRecent = SUM(CASE WHEN x.LastGoodRun >= DATEADD(DAY, -35, GETDATE()) THEN 1 ELSE 0 END),
       @pNotified = SUM(CASE WHEN j.enabled = 1 AND (j.notify_level_email > 0 OR j.notify_level_eventlog > 0 OR j.notify_level_page > 0) THEN 1 ELSE 0 END),
       @pLastGood = CONVERT(NVARCHAR(30), MAX(x.LastGoodRun), 120)
FROM msdb.dbo.sysjobs AS j
CROSS APPLY (
    SELECT (SELECT COUNT(*)
            FROM msdb.dbo.sysjobschedules AS js
            JOIN msdb.dbo.sysschedules AS sc ON sc.schedule_id = js.schedule_id
            WHERE js.job_id = j.job_id AND sc.enabled = 1) AS SchedCount,
           (SELECT MAX(msdb.dbo.agent_datetime(h.run_date, h.run_time))
            FROM msdb.dbo.sysjobhistory AS h
            WHERE h.job_id = j.job_id AND h.step_id = 0 AND h.run_status = 1) AS LastGoodRun
) AS x
WHERE EXISTS (SELECT 1
              FROM msdb.dbo.sysjobsteps AS st
              WHERE st.job_id = j.job_id
                AND (st.command LIKE ''%CHECKDB%''
                     OR st.command LIKE ''%CHECKALLOC%''
                     OR st.command LIKE ''%CHECKTABLE%''
                     OR st.command LIKE ''%CHECKCATALOG%''
                     OR st.command LIKE ''%DatabaseIntegrityCheck%''))
   OR j.name LIKE ''%CHECKDB%''
   OR j.name LIKE ''%integrity%''
   OR j.name LIKE ''%consistenc%'';';

        EXEC sys.sp_executesql @sql,
             N'@pJobs INT OUTPUT, @pEnabled INT OUTPUT, @pScheduled INT OUTPUT, @pRecent INT OUTPUT, @pNotified INT OUTPUT, @pLastGood NVARCHAR(30) OUTPUT',
             @pJobs = @Jobs OUTPUT,
             @pEnabled = @EnabledJobs OUTPUT,
             @pScheduled = @ScheduledJobs OUTPUT,
             @pRecent = @RecentJobs OUTPUT,
             @pNotified = @NotifiedJobs OUTPUT,
             @pLastGood = @LastGood OUTPUT;

        SET @DatabaseQueried = N'msdb';
        SET @Jobs = ISNULL(@Jobs, 0);
        SET @EnabledJobs = ISNULL(@EnabledJobs, 0);
        SET @ScheduledJobs = ISNULL(@ScheduledJobs, 0);
        SET @RecentJobs = ISNULL(@RecentJobs, 0);
        SET @NotifiedJobs = ISNULL(@NotifiedJobs, 0);

        IF @Jobs = 0
        BEGIN
            SET @Score = 0;
            SET @Finding = N'No SQL Agent job that performs DBCC CHECKDB or an equivalent integrity check was found in msdb (0 candidate jobs). Database consistency is not being verified on any schedule.';
        END
        ELSE IF @ScheduledJobs = 0
        BEGIN
            SET @Score = 1;
            SET @Finding = N'Found ' + CONVERT(NVARCHAR(10), @Jobs) + N' integrity-check job(s) in msdb, of which ' + CONVERT(NVARCHAR(10), @EnabledJobs) + N' are enabled, but none are attached to an enabled schedule. Last successful completion: ' + ISNULL(@LastGood, N'never') + N'.';
        END
        ELSE IF @RecentJobs = 0 OR @NotifiedJobs = 0
        BEGIN
            SET @Score = 2;
            SET @Finding = N'Found ' + CONVERT(NVARCHAR(10), @ScheduledJobs) + N' enabled and scheduled integrity-check job(s), but monitoring is incomplete: successful runs in the last 35 days = ' + CONVERT(NVARCHAR(10), @RecentJobs) + N', jobs with failure notification (email/event log/pager) = ' + CONVERT(NVARCHAR(10), @NotifiedJobs) + N'. Last successful completion: ' + ISNULL(@LastGood, N'never') + N'.';
        END
        ELSE
        BEGIN
            SET @Score = 3;
            SET @Finding = N'Found ' + CONVERT(NVARCHAR(10), @ScheduledJobs) + N' enabled integrity-check job(s) bound to an enabled schedule, ' + CONVERT(NVARCHAR(10), @RecentJobs) + N' with a successful run in the last 35 days and ' + CONVERT(NVARCHAR(10), @NotifiedJobs) + N' with failure notification configured. Last successful completion: ' + ISNULL(@LastGood, N'never') + N'.';
        END
    END TRY
    BEGIN CATCH
        SET @Score = 0;
        SET @DatabaseQueried = N'msdb';
        SET @Finding = N'Unable to read SQL Agent metadata from msdb, so DBCC CHECKDB scheduling could not be confirmed: ' + ISNULL(ERROR_MESSAGE(), N'unknown error');
    END CATCH
END

SET @Score = ISNULL(@Score, 0);
SET @Result = CASE WHEN @Score = 3 THEN N'Pass' WHEN @Score = 2 THEN N'Partial' ELSE N'Fail' END;
SET @DatabaseQueried = ISNULL(@DatabaseQueried, N'No database found to be queried');
SET @Finding = ISNULL(@Finding, N'No evidence collected.');

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;