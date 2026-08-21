/*
    Checklist item : 9.3.3 - Corruption detection alerting in place
    Scope          : SERVER
    Access         : READ-ONLY (catalog queries only)
    Purpose        : Confirm SQL Server Agent alerts exist, are enabled and are wired to a
                     notification target for corruption / I-O integrity errors 823, 824, 825
                     and for severity 24 (fatal hardware error) events.
*/
SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(256) = N'msdb';
DECLARE @Finding NVARCHAR(4000) = N'';

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @TotalAlerts INT = 0;
DECLARE @EnabledAlerts INT = 0;
DECLARE @Covered INT = 0;
DECLARE @Notified INT = 0;
DECLARE @CoveredList NVARCHAR(400) = N'';
DECLARE @EnabledOperators INT = 0;
DECLARE @MailProfiles INT = 0;
DECLARE @SuspectPages INT = 0;
DECLARE @AgentStatus NVARCHAR(60) = N'Unknown';
DECLARE @Sql NVARCHAR(MAX);

BEGIN TRY
    IF @EngineEdition IN (5, 6, 9, 11)
    BEGIN
        SET @DatabaseQueried = DB_NAME();
        SET @Score = 1;
        SET @Finding = N'EngineEdition ' + CAST(@EngineEdition AS NVARCHAR(10))
            + N' (Azure SQL Database / Synapse / SQL Edge). SQL Server Agent alerts and the msdb '
            + N'catalog are not available on this platform, so corruption alerting cannot be verified '
            + N'with T-SQL and requires manual review. Confirm that platform monitoring raises '
            + N'notifications for data corruption and I-O errors (823, 824, 825) and for severity 24 events.';
    END
    ELSE
    BEGIN
        IF HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE') = 1
           AND OBJECT_ID('sys.dm_server_services') IS NOT NULL
        BEGIN
            SELECT @AgentStatus = MAX(svc.status_desc)
            FROM sys.dm_server_services AS svc
            WHERE svc.servicename LIKE N'%Agent%';
        END

        SET @AgentStatus = ISNULL(@AgentStatus, N'Not installed / not visible');

        SET @Sql = N'
SELECT @pTotal   = ISNULL(COUNT(*), 0),
       @pEnabled = ISNULL(SUM(CASE WHEN a.enabled = 1 THEN 1 ELSE 0 END), 0)
FROM msdb.dbo.sysalerts AS a;

SELECT @pCovered  = ISNULL(COUNT(DISTINCT k.KeyName), 0),
       @pNotified = ISNULL(COUNT(DISTINCT CASE WHEN k.HasResponse = 1 THEN k.KeyName END), 0)
FROM (
    SELECT CASE WHEN a.message_id IN (823, 824, 825)
                THEN CAST(a.message_id AS NVARCHAR(10))
                ELSE N''SEV24'' END AS KeyName,
           CASE WHEN a.job_id <> ''00000000-0000-0000-0000-000000000000''
                  OR EXISTS (SELECT 1
                             FROM msdb.dbo.sysnotifications AS n
                             INNER JOIN msdb.dbo.sysoperators AS o ON o.id = n.operator_id
                             WHERE n.alert_id = a.id AND o.enabled = 1)
                THEN 1 ELSE 0 END AS HasResponse
    FROM msdb.dbo.sysalerts AS a
    WHERE a.enabled = 1
      AND (a.message_id IN (823, 824, 825) OR a.severity = 24)
) AS k;

SELECT @pList = @pList + k.KeyName + N'', ''
FROM (
    SELECT DISTINCT CASE WHEN a.message_id IN (823, 824, 825)
                         THEN CAST(a.message_id AS NVARCHAR(10))
                         ELSE N''SEV24'' END AS KeyName
    FROM msdb.dbo.sysalerts AS a
    WHERE a.enabled = 1
      AND (a.message_id IN (823, 824, 825) OR a.severity = 24)
) AS k;

SELECT @pOperators = ISNULL(COUNT(*), 0)
FROM msdb.dbo.sysoperators AS o
WHERE o.enabled = 1;

SELECT @pProfiles = ISNULL(COUNT(*), 0)
FROM msdb.dbo.sysmail_profile AS p;

SELECT @pSuspect = ISNULL(COUNT(*), 0)
FROM msdb.dbo.suspect_pages AS sp;';

        EXEC sys.sp_executesql @Sql,
             N'@pTotal INT OUTPUT, @pEnabled INT OUTPUT, @pCovered INT OUTPUT, @pNotified INT OUTPUT, @pList NVARCHAR(400) OUTPUT, @pOperators INT OUTPUT, @pProfiles INT OUTPUT, @pSuspect INT OUTPUT',
             @pTotal     = @TotalAlerts       OUTPUT,
             @pEnabled   = @EnabledAlerts     OUTPUT,
             @pCovered   = @Covered           OUTPUT,
             @pNotified  = @Notified          OUTPUT,
             @pList      = @CoveredList       OUTPUT,
             @pOperators = @EnabledOperators  OUTPUT,
             @pProfiles  = @MailProfiles      OUTPUT,
             @pSuspect   = @SuspectPages      OUTPUT;

        SET @CoveredList = ISNULL(@CoveredList, N'');

        IF LEN(@CoveredList) > 1
            SET @CoveredList = LEFT(@CoveredList, LEN(@CoveredList) - 1);

        IF LEN(@CoveredList) = 0
            SET @CoveredList = N'none';

        SET @Covered  = ISNULL(@Covered, 0);
        SET @Notified = ISNULL(@Notified, 0);

        IF @Covered >= 4 AND @Notified >= 4 AND @AgentStatus = N'Running'
            SET @Score = 3;
        ELSE IF @Covered >= 4 AND @Notified >= 4
            SET @Score = 2;
        ELSE IF @Covered >= 1
            SET @Score = 1;
        ELSE
            SET @Score = 0;

        SET @Finding =
              N'Corruption / I-O alert coverage: ' + CAST(@Covered AS NVARCHAR(10))
            + N' of 4 required categories enabled (message 823, 824, 825 and severity 24); covered: '
            + @CoveredList + N'. '
            + CAST(@Notified AS NVARCHAR(10))
            + N' of those categories notify an enabled operator or launch a response job. '
            + N'SQL Server Agent service status: ' + @AgentStatus + N'. '
            + N'Alerts defined on the instance: ' + CAST(ISNULL(@TotalAlerts, 0) AS NVARCHAR(10))
            + N' (' + CAST(ISNULL(@EnabledAlerts, 0) AS NVARCHAR(10)) + N' enabled). '
            + N'Enabled operators: ' + CAST(ISNULL(@EnabledOperators, 0) AS NVARCHAR(10))
            + N'; Database Mail profiles: ' + CAST(ISNULL(@MailProfiles, 0) AS NVARCHAR(10))
            + N'; rows currently in msdb.dbo.suspect_pages: '
            + CAST(ISNULL(@SuspectPages, 0) AS NVARCHAR(10)) + N'.';
    END
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'The corruption-alerting check could not complete (error '
        + CAST(ERROR_NUMBER() AS NVARCHAR(20)) + N': '
        + LEFT(ISNULL(ERROR_MESSAGE(), N'unknown error'), 500)
        + N'). This usually means the login lacks read access to msdb catalog views. '
        + N'Verify SQL Server Agent alerts for errors 823, 824, 825 and severity 24 manually.';
END CATCH

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;