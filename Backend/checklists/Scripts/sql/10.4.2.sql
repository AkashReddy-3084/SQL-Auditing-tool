SET NOCOUNT ON;

DECLARE @Result varchar(10);
DECLARE @Score int;
DECLARE @DatabaseQueried nvarchar(128);
DECLARE @Finding nvarchar(max);
DECLARE @EngineEdition int = CAST(SERVERPROPERTY('EngineEdition') AS int);
DECLARE @Edition nvarchar(128) = CAST(SERVERPROPERTY('Edition') AS nvarchar(128));

SET @DatabaseQueried = N'msdb';

/* Azure SQL Database — no SQL Agent jobs */
IF @EngineEdition = 5
BEGIN
    SET @Score = 3;
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
    SET @DatabaseQueried = N'None';
    SET @Finding = N'Platform is Azure SQL Database (EngineEdition=5). SQL Agent jobs and job-failure operator notifications are not available; checklist item is not applicable on this platform.';
    SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
    RETURN;
END;

IF DB_ID(N'msdb') IS NULL
BEGIN
    SET @Score = 0;
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
    SET @DatabaseQueried = N'None';
    SET @Finding = N'msdb is not present; SQL Agent job failure notification configuration cannot be audited.';
    SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
    RETURN;
END;

DECLARE @AgentStatusDesc nvarchar(64) = N'Unknown';

BEGIN TRY
    SELECT TOP (1)
        @AgentStatusDesc = status_desc
    FROM sys.dm_server_services
    WHERE servicename LIKE N'SQL Server Agent%';
END TRY
BEGIN CATCH
    SET @AgentStatusDesc = N'not reported';
END CATCH;

DECLARE @EnabledJobCount int = 0;
DECLARE @JobsWithFailureNotify int = 0;
DECLARE @JobsWithOperatorEmail int = 0;
DECLARE @JobsNotifyNoOperatorEmail int = 0;
DECLARE @MailProfileCount int = 0;
DECLARE @EnabledOperatorWithEmail int = 0;
DECLARE @EnabledFailureAlerts int = 0;
DECLARE @SampleMissing nvarchar(max) = N'';

BEGIN TRY
    SELECT
        @EnabledJobCount = COUNT(*)
    FROM msdb.dbo.sysjobs j
    WHERE j.enabled = 1
      AND j.name NOT LIKE N'syspolicy_purge_history';

    /* notify_level_email: bit 2 = failure; completion (3) also includes failure */
    ;WITH JobNotify AS (
        SELECT
            j.job_id,
            j.name AS job_name,
            j.notify_level_email,
            j.notify_email_operator_id,
            CASE WHEN (j.notify_level_email & 2) = 2 THEN 1 ELSE 0 END AS notifies_on_failure,
            CASE
                WHEN (j.notify_level_email & 2) = 2
                 AND j.notify_email_operator_id IS NOT NULL
                 AND j.notify_email_operator_id <> 0
                 AND o.id IS NOT NULL
                 AND ISNULL(o.enabled, 0) = 1
                 AND NULLIF(LTRIM(RTRIM(ISNULL(o.email_address, N''))), N'') IS NOT NULL
                THEN 1 ELSE 0
            END AS has_valid_failure_email_path
        FROM msdb.dbo.sysjobs j
        LEFT JOIN msdb.dbo.sysoperators o
            ON o.id = j.notify_email_operator_id
        WHERE j.enabled = 1
          AND j.name NOT LIKE N'syspolicy_purge_history'
    )
    SELECT
        @JobsWithFailureNotify = SUM(CASE WHEN notifies_on_failure = 1 THEN 1 ELSE 0 END),
        @JobsWithOperatorEmail = SUM(CASE WHEN has_valid_failure_email_path = 1 THEN 1 ELSE 0 END),
        @JobsNotifyNoOperatorEmail = SUM(CASE WHEN notifies_on_failure = 1 AND has_valid_failure_email_path = 0 THEN 1 ELSE 0 END)
    FROM JobNotify;

    SELECT @SampleMissing = STUFF((
        SELECT TOP (8) N', ' + j.name
        FROM msdb.dbo.sysjobs j
        WHERE j.enabled = 1
          AND j.name NOT LIKE N'syspolicy_purge_history'
          AND (
                (j.notify_level_email & 2) <> 2
             OR j.notify_email_operator_id IS NULL
             OR j.notify_email_operator_id = 0
             OR NOT EXISTS (
                    SELECT 1
                    FROM msdb.dbo.sysoperators o
                    WHERE o.id = j.notify_email_operator_id
                      AND o.enabled = 1
                      AND NULLIF(LTRIM(RTRIM(ISNULL(o.email_address, N''))), N'') IS NOT NULL
                )
          )
        ORDER BY j.name
        FOR XML PATH(N''), TYPE
    ).value(N'.[1]', N'nvarchar(max)'), 1, 2, N'');

    SELECT
        @MailProfileCount = COUNT(*)
    FROM msdb.dbo.sysmail_profile;

    SELECT
        @EnabledOperatorWithEmail = COUNT(*)
    FROM msdb.dbo.sysoperators o
    WHERE o.enabled = 1
      AND NULLIF(LTRIM(RTRIM(ISNULL(o.email_address, N''))), N'') IS NOT NULL;

    SELECT
        @EnabledFailureAlerts = COUNT(*)
    FROM msdb.dbo.sysalerts a
    INNER JOIN msdb.dbo.sysnotifications n
        ON n.alert_id = a.id
    INNER JOIN msdb.dbo.sysoperators o
        ON o.id = n.operator_id
    WHERE a.enabled = 1
      AND o.enabled = 1
      AND (
            n.notification_method & 1 = 1
         OR n.notification_method & 2 = 2
         OR n.notification_method & 4 = 4
      )
      AND (
            NULLIF(LTRIM(RTRIM(ISNULL(o.email_address, N''))), N'') IS NOT NULL
         OR NULLIF(LTRIM(RTRIM(ISNULL(o.pager_address, N''))), N'') IS NOT NULL
      );
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
    SET @Finding = CONCAT(N'Error reading SQL Agent job notification metadata: ', ERROR_MESSAGE());
    SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
    RETURN;
END CATCH;

DECLARE @CoveragePct decimal(5, 2) = NULL;
DECLARE @ValidCoveragePct decimal(5, 2) = NULL;

IF @EnabledJobCount > 0
BEGIN
    SET @CoveragePct = CAST(@JobsWithFailureNotify AS decimal(10, 2)) * 100.0 / CAST(@EnabledJobCount AS decimal(10, 2));
    SET @ValidCoveragePct = CAST(@JobsWithOperatorEmail AS decimal(10, 2)) * 100.0 / CAST(@EnabledJobCount AS decimal(10, 2));
END;

/* No enabled jobs — nothing that must alert */
IF @EnabledJobCount = 0
BEGIN
    SET @Score = 3;
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
    SET @Finding = CONCAT(
        N'No enabled user SQL Agent jobs found on ',
        CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)),
        N'. Job-failure team alerting is not applicable until jobs are deployed. ',
        N'SQL Agent service status: ', ISNULL(@AgentStatusDesc, N'not reported'),
        N'. Enabled operators with email: ', CAST(@EnabledOperatorWithEmail AS varchar(11)),
        N'. Enabled alerts with operator notification: ', CAST(@EnabledFailureAlerts AS varchar(11)),
        N'.'
    );
    SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
    RETURN;
END;

/*
  Primary control: per-job failure email to a valid enabled operator.
  Score on valid failure-email path coverage.
*/
IF @ValidCoveragePct = 100.0 AND @MailProfileCount > 0
    SET @Score = 3;
ELSE IF @ValidCoveragePct = 100.0 AND @MailProfileCount = 0
    SET @Score = 1; /* notify configured but Database Mail cannot deliver */
ELSE IF @ValidCoveragePct >= 95.0
    SET @Score = 2;
ELSE IF @ValidCoveragePct >= 75.0
    SET @Score = 1;
ELSE
    SET @Score = 0;

/* Weak per-job path but instance alerts + operators present and at least half of jobs covered — floor at 1 */
IF @Score = 0 AND @EnabledFailureAlerts > 0 AND @EnabledOperatorWithEmail > 0 AND @ValidCoveragePct >= 50.0
    SET @Score = 1;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding = CONCAT(
    N'Enabled user jobs: ', CAST(@EnabledJobCount AS varchar(11)),
    N'; jobs with failure email notify flag: ', CAST(@JobsWithFailureNotify AS varchar(11)),
    N' (', CASE WHEN @CoveragePct IS NULL THEN N'n/a' ELSE CAST(@CoveragePct AS varchar(16)) END, N'%)',
    N'; jobs with valid failure operator+email path: ', CAST(@JobsWithOperatorEmail AS varchar(11)),
    N' (', CASE WHEN @ValidCoveragePct IS NULL THEN N'n/a' ELSE CAST(@ValidCoveragePct AS varchar(16)) END, N'%)',
    N'; failure-notify without usable operator email: ', CAST(@JobsNotifyNoOperatorEmail AS varchar(11)),
    N'; missing/invalid samples: ', ISNULL(NULLIF(@SampleMissing, N''), N'(none)'),
    N'. Database Mail profiles: ', CAST(@MailProfileCount AS varchar(11)),
    N'; enabled operators with email: ', CAST(@EnabledOperatorWithEmail AS varchar(11)),
    N'; enabled alerts with operator notification: ', CAST(@EnabledFailureAlerts AS varchar(11)),
    N'. SQL Agent: ', ISNULL(@AgentStatusDesc, N'not reported'),
    N' (Edition=', ISNULL(@Edition, N'?'), N').'
);

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;