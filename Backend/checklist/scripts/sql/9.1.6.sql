/* Checklist 9.1.6 - Backup failures alerted and monitored
   Read-only. Inspects SQL Server Agent operators, backup job failure notifications,
   backup-related alerts and Database Mail readiness in msdb. */
SET NOCOUNT ON;

DECLARE @Result NVARCHAR(20);
DECLARE @Score INT = 2;
DECLARE @DatabaseQueried NVARCHAR(256) = N'msdb';
DECLARE @Finding NVARCHAR(MAX) = N'';
DECLARE @Skip BIT = 0;
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

CREATE TABLE #Env
(
    DatabaseMailEnabled INT NULL,
    AgentXPsEnabled     INT NULL,
    EnabledOperators    INT NULL,
    MailProfiles        INT NULL
);

CREATE TABLE #BackupJobs
(
    JobName                SYSNAME NOT NULL,
    NotifyEmailLevel       INT NULL,
    EmailOperator          SYSNAME NULL,
    NotifyEventLogLevel    INT NULL,
    HasFailureNotification BIT NOT NULL
);

CREATE TABLE #BackupAlerts
(
    AlertName          SYSNAME NOT NULL,
    MessageId          INT NULL,
    Severity           INT NULL,
    IsEnabled          BIT NOT NULL,
    HasEnabledOperator BIT NOT NULL
);

IF @EngineEdition IN (5, 6, 9, 11)
BEGIN
    SET @Skip = 1;
    SET @Score = 2;
    SET @DatabaseQueried = DB_NAME();
    SET @Finding = N'Azure SQL Database / Synapse engine detected (EngineEdition '
        + CAST(@EngineEdition AS NVARCHAR(10))
        + N'). SQL Server Agent and msdb are not present, so backup failure alerting cannot be read from instance metadata. Manual verification of Azure Monitor / Log Analytics backup alert rules is required.';
END

IF @Skip = 0
   AND (NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = N'msdb' AND state = 0)
        OR ISNULL(HAS_DBACCESS(N'msdb'), 0) = 0)
BEGIN
    SET @Skip = 1;
    SET @Score = 2;
    SET @Finding = N'msdb is offline or not accessible to the audit login, so SQL Server Agent operators, job failure notifications and alerts could not be inspected. Re-run with a login that has read access to msdb, or verify backup failure alerting manually.';
END

IF @Skip = 0
BEGIN
    DECLARE @sql NVARCHAR(MAX);

    SET @sql = N'
INSERT INTO #Env (DatabaseMailEnabled, AgentXPsEnabled, EnabledOperators, MailProfiles)
SELECT
    ISNULL((SELECT CAST(c.value_in_use AS INT) FROM sys.configurations c WHERE c.name = ''Database Mail XPs''), 0),
    ISNULL((SELECT CAST(c.value_in_use AS INT) FROM sys.configurations c WHERE c.name = ''Agent XPs''), 0),
    (SELECT COUNT(*) FROM msdb.dbo.sysoperators o
      WHERE o.enabled = 1
        AND (NULLIF(LTRIM(RTRIM(o.email_address)), '''') IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(o.pager_address)), '''') IS NOT NULL
          OR NULLIF(LTRIM(RTRIM(o.netsend_address)), '''') IS NOT NULL)),
    (SELECT COUNT(*) FROM msdb.dbo.sysmail_profile);';
    EXEC sys.sp_executesql @sql;

    SET @sql = N'
INSERT INTO #BackupJobs (JobName, NotifyEmailLevel, EmailOperator, NotifyEventLogLevel, HasFailureNotification)
SELECT DISTINCT
    j.name,
    j.notify_level_email,
    oe.name,
    j.notify_level_eventlog,
    CAST(CASE
            WHEN (j.notify_level_email   IN (2, 3) AND oe.id IS NOT NULL AND oe.enabled = 1)
              OR (j.notify_level_page    IN (2, 3) AND op.id IS NOT NULL AND op.enabled = 1)
              OR (j.notify_level_netsend IN (2, 3) AND onet.id IS NOT NULL AND onet.enabled = 1)
            THEN 1 ELSE 0
         END AS BIT)
FROM msdb.dbo.sysjobs AS j
INNER JOIN msdb.dbo.sysjobsteps AS s ON s.job_id = j.job_id
LEFT JOIN msdb.dbo.sysoperators AS oe   ON oe.id   = j.notify_email_operator_id
LEFT JOIN msdb.dbo.sysoperators AS op   ON op.id   = j.notify_page_operator_id
LEFT JOIN msdb.dbo.sysoperators AS onet ON onet.id = j.notify_netsend_operator_id
LEFT JOIN msdb.dbo.syscategories AS c   ON c.category_id = j.category_id
WHERE j.enabled = 1
  AND (   s.command LIKE ''%BACKUP DATABASE%''
       OR s.command LIKE ''%BACKUP LOG%''
       OR s.command LIKE ''%DatabaseBackup%''
       OR s.command LIKE ''%sqlbackup%''
       OR j.name LIKE ''%backup%''
       OR j.name LIKE ''%back up%''
       OR (c.name = ''Database Maintenance'' AND s.command LIKE ''%Back Up Database%''));';
    EXEC sys.sp_executesql @sql;

    SET @sql = N'
INSERT INTO #BackupAlerts (AlertName, MessageId, Severity, IsEnabled, HasEnabledOperator)
SELECT
    a.name,
    a.message_id,
    a.severity,
    CAST(CASE WHEN a.enabled = 1 THEN 1 ELSE 0 END AS BIT),
    CAST(CASE WHEN EXISTS (SELECT 1
                           FROM msdb.dbo.sysnotifications AS n
                           INNER JOIN msdb.dbo.sysoperators AS o2 ON o2.id = n.operator_id
                           WHERE n.alert_id = a.id AND o2.enabled = 1)
              THEN 1 ELSE 0 END AS BIT)
FROM msdb.dbo.sysalerts AS a
WHERE a.message_id IN (3013, 3041, 3043, 3201, 3202, 17053, 18204, 18210)
   OR a.name LIKE ''%backup%'';';
    EXEC sys.sp_executesql @sql;

    DECLARE @MailEnabled INT = 0, @AgentXPs INT = 0, @Operators INT = 0, @MailProfiles INT = 0;
    SELECT @MailEnabled  = ISNULL(DatabaseMailEnabled, 0),
           @AgentXPs     = ISNULL(AgentXPsEnabled, 0),
           @Operators    = ISNULL(EnabledOperators, 0),
           @MailProfiles = ISNULL(MailProfiles, 0)
    FROM #Env;

    DECLARE @TotalBackupJobs INT = (SELECT COUNT(*) FROM #BackupJobs);
    DECLARE @NotifiedJobs INT = (SELECT COUNT(*) FROM #BackupJobs WHERE HasFailureNotification = 1);
    DECLARE @EventLogOnlyJobs INT = (SELECT COUNT(*) FROM #BackupJobs
                                     WHERE HasFailureNotification = 0 AND NotifyEventLogLevel IN (2, 3));
    DECLARE @BackupAlertCount INT = (SELECT COUNT(*) FROM #BackupAlerts WHERE IsEnabled = 1);
    DECLARE @BackupAlertsNotified INT = (SELECT COUNT(*) FROM #BackupAlerts WHERE IsEnabled = 1 AND HasEnabledOperator = 1);

    DECLARE @UnnotifiedList NVARCHAR(MAX);
    SELECT @UnnotifiedList = STUFF((SELECT N', ' + t.JobName
                                    FROM (SELECT TOP (10) JobName
                                          FROM #BackupJobs
                                          WHERE HasFailureNotification = 0
                                          ORDER BY JobName) AS t
                                    ORDER BY t.JobName
                                    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

    DECLARE @Detail NVARCHAR(MAX) =
          N'Database Mail XPs: ' + CASE WHEN @MailEnabled = 1 THEN N'enabled' ELSE N'disabled' END
        + N'; Database Mail profiles: ' + CAST(@MailProfiles AS NVARCHAR(10))
        + N'; Agent XPs: ' + CASE WHEN @AgentXPs = 1 THEN N'enabled' ELSE N'disabled' END
        + N'; enabled operators with a delivery address: ' + CAST(@Operators AS NVARCHAR(10))
        + N'; enabled backup jobs detected: ' + CAST(@TotalBackupJobs AS NVARCHAR(10))
        + N' (notifying an enabled operator on failure: ' + CAST(@NotifiedJobs AS NVARCHAR(10))
        + N', event-log only: ' + CAST(@EventLogOnlyJobs AS NVARCHAR(10)) + N')'
        + N'; enabled backup-related alerts: ' + CAST(@BackupAlertCount AS NVARCHAR(10))
        + N' (notifying an enabled operator: ' + CAST(@BackupAlertsNotified AS NVARCHAR(10)) + N')'
        + CASE WHEN @UnnotifiedList IS NULL THEN N''
               ELSE N'; backup jobs without failure notification (up to 10 shown): ' + @UnnotifiedList END
        + N'.';

    IF @AgentXPs <> 1
    BEGIN
        SET @Score = 1;
        SET @Finding = N'SQL Server Agent XPs are disabled on this instance, so Agent jobs, operators and alerts cannot raise backup failure notifications. ' + @Detail;
    END
    ELSE IF @Operators = 0 AND @NotifiedJobs = 0 AND @BackupAlertsNotified = 0
    BEGIN
        SET @Score = 1;
        SET @Finding = N'No enabled SQL Server Agent operator, job failure notification or backup alert notification is configured, so backup failures would go unreported. ' + @Detail;
    END
    ELSE IF @TotalBackupJobs = 0 AND @BackupAlertCount = 0
    BEGIN
        SET @Score = 2;
        SET @Finding = N'No enabled backup jobs and no backup-related alerts were found in msdb, so backups appear to be driven by an external scheduler or backup product whose failure alerting cannot be verified from this instance; manual confirmation is required. ' + @Detail;
    END
    ELSE IF (@TotalBackupJobs > 0 AND @NotifiedJobs = @TotalBackupJobs AND @Operators > 0 AND @MailEnabled = 1 AND @MailProfiles > 0)
         OR (@TotalBackupJobs = 0 AND @BackupAlertsNotified > 0 AND @Operators > 0 AND @MailEnabled = 1 AND @MailProfiles > 0)
    BEGIN
        SET @Score = 3;
        SET @Finding = N'Backup failures are alerted and monitored: Database Mail is enabled with a configured profile, enabled operators exist, and every detected backup job (or backup alert) notifies an enabled operator on failure. ' + @Detail;
    END
    ELSE
    BEGIN
        SET @Score = 2;
        SET @Finding = N'Backup failure alerting is only partially configured: '
            + CASE WHEN @MailEnabled <> 1 THEN N'Database Mail XPs are disabled so email notifications cannot be delivered; '
                   WHEN @MailProfiles = 0 THEN N'no Database Mail profile exists so email notifications cannot be delivered; '
                   ELSE N'' END
            + CASE WHEN @Operators = 0 THEN N'no enabled operator with a delivery address exists; ' ELSE N'' END
            + CASE WHEN @TotalBackupJobs > 0 AND @NotifiedJobs < @TotalBackupJobs
                   THEN CAST(@TotalBackupJobs - @NotifiedJobs AS NVARCHAR(10)) + N' of '
                        + CAST(@TotalBackupJobs AS NVARCHAR(10)) + N' enabled backup jobs do not notify an enabled operator on failure; '
                   ELSE N'' END
            + CASE WHEN @BackupAlertCount > 0 AND @BackupAlertsNotified = 0
                   THEN N'backup-related alerts exist but no enabled operator is notified by them; '
                   ELSE N'' END
            + @Detail;
    END
END

DROP TABLE #BackupAlerts;
DROP TABLE #BackupJobs;
DROP TABLE #Env;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result,
       @Score AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding AS Finding;