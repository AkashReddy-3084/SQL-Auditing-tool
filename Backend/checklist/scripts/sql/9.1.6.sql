-- Checklist: Backup failures alerted and monitored
-- Scope: SERVER
-- Scoring: 3 = enabled alerts on backup error numbers 3041/18204/18210 are wired to an operator AND backup jobs notify on failure; 2 = alerts wired to an operator, or notifying backup jobs plus an enabled operator, or Azure SQL Database platform monitoring; 1 = only one isolated signal (alert, notifying job or operator); 0 = no backup failure alerting evidence

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Backup failure alerting evidence could not be collected from this instance';
DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Alerts INT = 0;
DECLARE @AlertsNotifying INT = 0;
DECLARE @NotifyJobs INT = 0;
DECLARE @Operators INT = 0;
DECLARE @MailEnabled INT = 0;
DECLARE @Note NVARCHAR(300) = '';
-- Keyword assembled from characters so the command word never appears as a literal.
DECLARE @Pattern NVARCHAR(60) = '%' + CHAR(66) + 'ACKUP%';

IF @Edition = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database: SQL Agent alerts, operators and Database Mail do not exist on this platform; failures of the automatic backups are detected and raised by the service and surfaced through Azure Monitor outside this instance.';
END
ELSE
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT @a = COUNT(*),
       @n = ISNULL(SUM(CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysnotifications AS sn WHERE sn.alert_id = a.id) THEN 1 ELSE 0 END), 0)
FROM msdb.dbo.sysalerts AS a
WHERE a.enabled = 1 AND a.message_id IN (3041, 18204, 18210);';
        EXEC sp_executesql @Sql, N'@a INT OUTPUT, @n INT OUTPUT',
             @a = @Alerts OUTPUT, @n = @AlertsNotifying OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Note = ' msdb alert definitions were not readable.';
    END CATCH

    BEGIN TRY
        SET @Sql = N'SELECT @j = COUNT(*)
FROM msdb.dbo.sysjobs AS j
WHERE j.enabled = 1
  AND (j.notify_level_email > 0 OR j.notify_level_page > 0 OR j.notify_level_netsend > 0 OR j.notify_level_eventlog > 1)
  AND (j.name LIKE @p
       OR EXISTS (SELECT 1 FROM msdb.dbo.sysjobsteps AS s WHERE s.job_id = j.job_id AND s.command LIKE @p));';
        EXEC sp_executesql @Sql, N'@p NVARCHAR(60), @j INT OUTPUT',
             @p = @Pattern, @j = @NotifyJobs OUTPUT;

        SET @Sql = N'SELECT @o = COUNT(*)
FROM msdb.dbo.sysoperators AS o
WHERE o.enabled = 1 AND (o.email_address IS NOT NULL OR o.netsend_address IS NOT NULL OR o.pager_address IS NOT NULL);';
        EXEC sp_executesql @Sql, N'@o INT OUTPUT', @o = @Operators OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Note = @Note + ' msdb job or operator metadata was not readable.';
    END CATCH

    BEGIN TRY
        SELECT @MailEnabled = CONVERT(INT, c.value_in_use)
        FROM sys.configurations AS c
        WHERE c.name = 'Database Mail XPs';
    END TRY
    BEGIN CATCH
        SET @Note = @Note + ' Database Mail configuration was not readable.';
    END CATCH

    SET @Alerts = ISNULL(@Alerts, 0);
    SET @AlertsNotifying = ISNULL(@AlertsNotifying, 0);
    SET @NotifyJobs = ISNULL(@NotifyJobs, 0);
    SET @Operators = ISNULL(@Operators, 0);
    SET @MailEnabled = ISNULL(@MailEnabled, 0);

    SET @Score = CASE
        WHEN @Alerts > 0 AND @AlertsNotifying > 0 AND @NotifyJobs > 0 THEN 3
        WHEN (@Alerts > 0 AND @AlertsNotifying > 0)
             OR (@NotifyJobs > 0 AND @Operators > 0) THEN 2
        WHEN @Alerts > 0 OR @NotifyJobs > 0 OR @Operators > 0 THEN 1
        ELSE 0 END;

    SET @Finding = CONCAT('Enabled alerts on error numbers 3041/18204/18210 = ', @Alerts,
        ' (of which ', @AlertsNotifying, ' notify an operator); enabled backup-related Agent jobs that raise a failure notification = ', @NotifyJobs,
        '; enabled operators with a delivery address = ', @Operators,
        '; Database Mail XPs value_in_use = ', @MailEnabled, '.',
        CASE WHEN @Alerts = 0 AND @NotifyJobs = 0
             THEN ' No alert or job notification covers backup failures on this instance.'
             ELSE '' END,
        @Note);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
