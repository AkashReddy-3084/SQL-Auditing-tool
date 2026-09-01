-- Checklist: SLA breach triggers alerts
-- Scope: SERVER
-- Scoring: 3 = an SLA-relevant alert condition exists, is routed to an enabled operator with a delivery address, Database Mail is configured and scheduled jobs raise failure notifications; 2 = alerts reach an enabled operator but no SLA-specific condition or job hook is defined, or platform-managed on Azure SQL Database; 1 = alerts or job notifications exist but the delivery chain is broken; 0 = nothing would raise a notification
SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'SLA breach alerting evidence was unavailable';
DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Alerts INT = 0;
DECLARE @PerfAlerts INT = 0;
DECLARE @SevAlerts INT = 0;
DECLARE @AlertsToOperator INT = 0;
DECLARE @Operators INT = 0;
DECLARE @MailProfiles INT = 0;
DECLARE @MailXps INT = 0;
DECLARE @NotifyJobs INT = 0;
DECLARE @ReadNote NVARCHAR(300) = '';
DECLARE @M TABLE (K NVARCHAR(40), V INT NULL);

IF @Edition = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database (EngineEdition 5): SQL Server Agent alerts, operators and Database Mail do not exist, so SLA breach notification is delivered by platform Azure Monitor alert rules and action groups that are configured outside the engine.';
END
ELSE
BEGIN
    SET @Sql = N'
SELECT ''Alerts'', COUNT(*) FROM msdb.dbo.sysalerts WHERE enabled = 1
UNION ALL SELECT ''PerfAlerts'', COUNT(*) FROM msdb.dbo.sysalerts WHERE enabled = 1 AND (performance_condition IS NOT NULL OR wmi_query IS NOT NULL)
UNION ALL SELECT ''SevAlerts'', COUNT(*) FROM msdb.dbo.sysalerts WHERE enabled = 1 AND severity >= 16
UNION ALL SELECT ''AlertsToOperator'', COUNT(DISTINCT a.id) FROM msdb.dbo.sysalerts AS a INNER JOIN msdb.dbo.sysnotifications AS n ON n.alert_id = a.id INNER JOIN msdb.dbo.sysoperators AS o ON o.id = n.operator_id WHERE a.enabled = 1 AND o.enabled = 1
UNION ALL SELECT ''Operators'', COUNT(*) FROM msdb.dbo.sysoperators WHERE enabled = 1 AND ((email_address IS NOT NULL AND LTRIM(RTRIM(email_address)) <> '''') OR (pager_address IS NOT NULL AND LTRIM(RTRIM(pager_address)) <> ''''))
UNION ALL SELECT ''MailProfiles'', COUNT(*) FROM msdb.dbo.sysmail_profile
UNION ALL SELECT ''MailXps'', ISNULL((SELECT CONVERT(INT, c.value_in_use) FROM sys.configurations AS c WHERE c.name = ''Database Mail XPs''), 0)
UNION ALL SELECT ''NotifyJobs'', COUNT(DISTINCT j.job_id) FROM msdb.dbo.sysjobs AS j INNER JOIN msdb.dbo.sysjobschedules AS js ON js.job_id = j.job_id INNER JOIN msdb.dbo.sysschedules AS s ON s.schedule_id = js.schedule_id AND s.enabled = 1 WHERE j.enabled = 1 AND (j.notify_level_email > 0 OR j.notify_level_eventlog > 0)';

    BEGIN TRY
        INSERT INTO @M (K, V) EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        SET @ReadNote = ' One or more SQL Agent alerting sources could not be read: ' + LEFT(ISNULL(ERROR_MESSAGE(), ''), 150) + '.';
    END CATCH;

    SELECT @Alerts = ISNULL(MAX(CASE WHEN K = 'Alerts' THEN V END), 0),
           @PerfAlerts = ISNULL(MAX(CASE WHEN K = 'PerfAlerts' THEN V END), 0),
           @SevAlerts = ISNULL(MAX(CASE WHEN K = 'SevAlerts' THEN V END), 0),
           @AlertsToOperator = ISNULL(MAX(CASE WHEN K = 'AlertsToOperator' THEN V END), 0),
           @Operators = ISNULL(MAX(CASE WHEN K = 'Operators' THEN V END), 0),
           @MailProfiles = ISNULL(MAX(CASE WHEN K = 'MailProfiles' THEN V END), 0),
           @MailXps = ISNULL(MAX(CASE WHEN K = 'MailXps' THEN V END), 0),
           @NotifyJobs = ISNULL(MAX(CASE WHEN K = 'NotifyJobs' THEN V END), 0)
    FROM @M;

    SET @Score = CASE
        WHEN (@PerfAlerts > 0 OR @SevAlerts > 0) AND @AlertsToOperator > 0 AND @Operators > 0
             AND @MailProfiles > 0 AND @MailXps = 1 AND @NotifyJobs > 0 THEN 3
        WHEN @AlertsToOperator > 0 AND @Operators > 0 AND (@MailProfiles > 0 OR @NotifyJobs > 0) THEN 2
        WHEN @Alerts > 0 OR @NotifyJobs > 0 THEN 1
        ELSE 0
    END;

    SET @Finding = CONCAT(
        'Enabled alerts = ', @Alerts, ', of which ', @PerfAlerts,
        ' use a performance or WMI condition and ', @SevAlerts, ' cover severity 16 or above',
        '; alerts wired to an enabled operator = ', @AlertsToOperator,
        '; enabled operators with an email or pager address = ', @Operators,
        '; Database Mail profiles = ', @MailProfiles, ' with Database Mail XPs = ', @MailXps,
        '; scheduled jobs raising a failure notification = ', @NotifyJobs, '.',
        CASE WHEN @Alerts = 0 AND @NotifyJobs = 0 THEN ' No alert or job notification exists, so an SLA breach would go unannounced.' ELSE '' END,
        @ReadNote);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;