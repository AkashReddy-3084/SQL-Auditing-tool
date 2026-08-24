SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @DatabaseQueried NVARCHAR(128) = N'msdb';

IF @EngineEdition = 5
BEGIN
    SELECT
        CAST('Fail' AS NVARCHAR(20)) AS Result,
        CAST(0 AS INT) AS Score,
        CAST(N'N/A' AS NVARCHAR(128)) AS DatabaseQueried,
        CAST('Azure SQL Database does not host SQL Agent jobs/operators; failure notification configuration cannot be verified from this engine. Check Azure Monitor/ADF/Fabric alerts externally.' AS NVARCHAR(4000)) AS Finding;
    RETURN;
END;

IF DB_ID(N'msdb') IS NULL
BEGIN
    SELECT
        CAST('Fail' AS NVARCHAR(20)) AS Result,
        CAST(0 AS INT) AS Score,
        CAST(N'None.' AS NVARCHAR(128)) AS DatabaseQueried,
        CAST('msdb database not found; cannot verify SQL Agent failure notifications.' AS NVARCHAR(4000)) AS Finding;
    RETURN;
END;

IF OBJECT_ID(N'msdb.dbo.sysjobs') IS NULL
BEGIN
    SELECT
        CAST('Fail' AS NVARCHAR(20)) AS Result,
        CAST(0 AS INT) AS Score,
        CAST(@DatabaseQueried AS NVARCHAR(128)) AS DatabaseQueried,
        CAST('SQL Agent job tables are unavailable; failure notification settings cannot be audited.' AS NVARCHAR(4000)) AS Finding;
    RETURN;
END;

DECLARE @EnabledJobCount INT = 0;
DECLARE @JobsWithFailureNotify INT = 0;
DECLARE @EnabledOperatorCount INT = 0;
DECLARE @MailProfileCount INT = 0;
DECLARE @FailureAlertCount INT = 0;
DECLARE @JobsMissingNotify INT = 0;
DECLARE @CoveragePct DECIMAL(5, 2) = 0;
DECLARE @HasNotifyInfra BIT = 0;
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(20);
DECLARE @Finding NVARCHAR(4000);

SELECT @EnabledJobCount = COUNT(*)
FROM msdb.dbo.sysjobs j
WHERE j.enabled = 1;

-- Failure notify when level is failure(2) or completion(3) with operator, or event log on failure/completion
SELECT @JobsWithFailureNotify = COUNT(*)
FROM msdb.dbo.sysjobs j
WHERE j.enabled = 1
  AND (
        (j.notify_level_email IN (2, 3) AND j.notify_email_operator_id > 0)
        OR (j.notify_level_page IN (2, 3) AND j.notify_page_operator_id > 0)
        OR (j.notify_level_netsend IN (2, 3) AND j.notify_netsend_operator_id > 0)
        OR j.notify_level_eventlog IN (2, 3)
      );

IF OBJECT_ID(N'msdb.dbo.sysoperators') IS NOT NULL
BEGIN
    SELECT @EnabledOperatorCount = COUNT(*)
    FROM msdb.dbo.sysoperators
    WHERE enabled = 1;
END;

IF OBJECT_ID(N'msdb.dbo.sysmail_profile') IS NOT NULL
BEGIN
    SELECT @MailProfileCount = COUNT(*)
    FROM msdb.dbo.sysmail_profile;
END;

IF OBJECT_ID(N'msdb.dbo.sysalerts') IS NOT NULL
   AND OBJECT_ID(N'msdb.dbo.sysnotifications') IS NOT NULL
BEGIN
    SELECT @FailureAlertCount = COUNT(*)
    FROM msdb.dbo.sysalerts a
    WHERE a.enabled = 1
      AND (
            a.has_notification = 1
            OR EXISTS (
                SELECT 1
                FROM msdb.dbo.sysnotifications n
                WHERE n.alert_id = a.id
              )
          );
END
ELSE IF OBJECT_ID(N'msdb.dbo.sysalerts') IS NOT NULL
BEGIN
    SELECT @FailureAlertCount = COUNT(*)
    FROM msdb.dbo.sysalerts a
    WHERE a.enabled = 1
      AND a.has_notification = 1;
END;

SET @JobsMissingNotify = CASE WHEN @EnabledJobCount > @JobsWithFailureNotify THEN @EnabledJobCount - @JobsWithFailureNotify ELSE 0 END;
SET @HasNotifyInfra = CASE
    WHEN @EnabledOperatorCount > 0 OR @MailProfileCount > 0 OR @FailureAlertCount > 0 THEN 1
    ELSE 0
END;

IF @EnabledJobCount > 0
    SET @CoveragePct = CAST(@JobsWithFailureNotify AS DECIMAL(5, 2)) * 100.0 / CAST(@EnabledJobCount AS DECIMAL(5, 2));
ELSE
    SET @CoveragePct = 0;

IF @EnabledJobCount = 0
BEGIN
    IF @FailureAlertCount > 0 AND @HasNotifyInfra = 1
        SET @Score = 2;
    ELSE
        SET @Score = 0;

    SET @Finding = CASE
        WHEN @Score >= 2 THEN
            N'No enabled SQL Agent jobs found; ' + CAST(@FailureAlertCount AS NVARCHAR(20))
            + N' enabled alert(s) with notification present. Partial credit for alert-based monitoring only; confirm ETL orchestration notifications outside Agent if used.'
        ELSE
            N'No enabled SQL Agent jobs and no notified alerts/operators found. Cannot confirm that failures trigger notifications.'
    END;
END
ELSE IF @JobsWithFailureNotify = @EnabledJobCount AND @HasNotifyInfra = 1
BEGIN
    SET @Score = 3;
    SET @Finding = N'All ' + CAST(@EnabledJobCount AS NVARCHAR(20))
        + N' enabled SQL Agent job(s) notify on failure (email/page/netsend/eventlog). Operators enabled: '
        + CAST(@EnabledOperatorCount AS NVARCHAR(20))
        + N'; Database Mail profiles: ' + CAST(@MailProfileCount AS NVARCHAR(20))
        + N'; notified alerts: ' + CAST(@FailureAlertCount AS NVARCHAR(20)) + N'.';
END
ELSE IF @JobsWithFailureNotify = @EnabledJobCount AND @HasNotifyInfra = 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'All ' + CAST(@EnabledJobCount AS NVARCHAR(20))
        + N' enabled job(s) have failure notify levels set, but no enabled operators/Database Mail profiles/notified alerts were found. Notifications may not be deliverable.';
END
ELSE IF @HasNotifyInfra = 1 AND @CoveragePct >= 50.0
BEGIN
    SET @Score = 2;
    SET @Finding = N'Failure notification coverage is partial: '
        + CAST(@JobsWithFailureNotify AS NVARCHAR(20)) + N'/'
        + CAST(@EnabledJobCount AS NVARCHAR(20))
        + N' enabled job(s) (' + CAST(CAST(@CoveragePct AS DECIMAL(5, 1)) AS NVARCHAR(20))
        + N'%). Missing notify on ' + CAST(@JobsMissingNotify AS NVARCHAR(20))
        + N' job(s). Enabled operators: ' + CAST(@EnabledOperatorCount AS NVARCHAR(20))
        + N'; mail profiles: ' + CAST(@MailProfileCount AS NVARCHAR(20))
        + N'; notified alerts: ' + CAST(@FailureAlertCount AS NVARCHAR(20)) + N'.';
END
ELSE IF @HasNotifyInfra = 1 OR @JobsWithFailureNotify > 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'Weak failure notification posture: '
        + CAST(@JobsWithFailureNotify AS NVARCHAR(20)) + N'/'
        + CAST(@EnabledJobCount AS NVARCHAR(20))
        + N' enabled job(s) notify on failure. Enabled operators: '
        + CAST(@EnabledOperatorCount AS NVARCHAR(20))
        + N'; mail profiles: ' + CAST(@MailProfileCount AS NVARCHAR(20))
        + N'; notified alerts: ' + CAST(@FailureAlertCount AS NVARCHAR(20)) + N'.';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = N'None of ' + CAST(@EnabledJobCount AS NVARCHAR(20))
        + N' enabled SQL Agent job(s) notify on failure, and no enabled operators/Database Mail profiles/notified alerts were found.';
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    CAST(@Result AS NVARCHAR(20)) AS Result,
    CAST(@Score AS INT) AS Score,
    CAST(@DatabaseQueried AS NVARCHAR(128)) AS DatabaseQueried,
    CAST(@Finding AS NVARCHAR(4000)) AS Finding;