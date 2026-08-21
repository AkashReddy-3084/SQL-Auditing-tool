/* Checklist 10.4.2 - Job failures alert the responsible team
   Read-only. Confirms enabled SQL Server Agent jobs notify an enabled operator on failure
   and that a Database Mail delivery path exists. */
SET NOCOUNT ON;

DECLARE @EngineEdition   INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Result          NVARCHAR(50);
DECLARE @Score           INT = 0;
DECLARE @Finding         NVARCHAR(4000) = N'';
DECLARE @DatabaseQueried NVARCHAR(128) = N'msdb';

DECLARE @Total     INT = 0;
DECLARE @Notified  INT = 0;
DECLARE @Operators INT = 0;
DECLARE @Profiles  INT = 0;
DECLARE @DbMailXps INT = 0;
DECLARE @Pct       DECIMAL(5,1) = 0.0;
DECLARE @Sample    NVARCHAR(1000) = NULL;

CREATE TABLE #JobNotify
(
    JobName                SYSNAME NOT NULL,
    HasFailureNotification BIT     NOT NULL
);

CREATE TABLE #MailInfra
(
    EnabledEmailOperators INT NOT NULL,
    MailProfiles          INT NOT NULL
);

/* Azure SQL Database hosts no SQL Server Agent and blocks msdb cross-database references. */
IF @EngineEdition = 5
BEGIN
    SET @DatabaseQueried = DB_NAME();
    SET @Score = 0;
    SET @Finding = N'Azure SQL Database does not host SQL Server Agent, so job failure notification cannot be read from msdb. '
                 + N'Verify manually that Elastic Jobs, Azure Automation runbooks or Logic Apps used for scheduled work have failure alert rules routed to the responsible team via Azure Monitor action groups.';
END
ELSE
BEGIN
    /* msdb is reached through dynamic SQL so the batch compiles on engines without SQL Agent. */
    INSERT INTO #JobNotify (JobName, HasFailureNotification)
    EXEC sys.sp_executesql N'
SELECT
    j.name,
    CASE
        WHEN (j.notify_level_email   IN (2,3) AND oe.id  IS NOT NULL AND oe.enabled  = 1
              AND oe.email_address IS NOT NULL AND LEN(oe.email_address) > 0)
          OR (j.notify_level_netsend IN (2,3) AND onet.id IS NOT NULL AND onet.enabled = 1)
          OR (j.notify_level_page    IN (2,3) AND opg.id  IS NOT NULL AND opg.enabled  = 1)
        THEN 1 ELSE 0
    END
FROM msdb.dbo.sysjobs AS j
LEFT JOIN msdb.dbo.sysoperators AS oe   ON oe.id   = j.notify_email_operator_id
LEFT JOIN msdb.dbo.sysoperators AS onet ON onet.id = j.notify_netsend_operator_id
LEFT JOIN msdb.dbo.sysoperators AS opg  ON opg.id  = j.notify_page_operator_id
WHERE j.enabled = 1;';

    INSERT INTO #MailInfra (EnabledEmailOperators, MailProfiles)
    EXEC sys.sp_executesql N'
SELECT
    (SELECT COUNT(*) FROM msdb.dbo.sysoperators AS o
      WHERE o.enabled = 1 AND o.email_address IS NOT NULL AND LEN(o.email_address) > 0),
    (SELECT COUNT(*) FROM msdb.dbo.sysmail_profile);';

    SELECT
        @Total    = COUNT(*),
        @Notified = ISNULL(SUM(CAST(jn.HasFailureNotification AS INT)), 0)
    FROM #JobNotify AS jn;

    SELECT TOP (1)
        @Operators = mi.EnabledEmailOperators,
        @Profiles  = mi.MailProfiles
    FROM #MailInfra AS mi;

    SELECT @DbMailXps = CAST(c.value_in_use AS INT)
    FROM sys.configurations AS c
    WHERE c.name = N'Database Mail XPs';

    SET @Sample =
        STUFF((SELECT TOP (5) N', ' + jn.JobName
               FROM #JobNotify AS jn
               WHERE jn.HasFailureNotification = 0
               ORDER BY jn.JobName
               FOR XML PATH(N''), TYPE).value('.', 'NVARCHAR(1000)'), 1, 2, N'');

    IF @Total = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = N'No enabled SQL Server Agent jobs are visible to the audit login on this instance. '
                     + N'Either the instance runs no scheduled jobs, or the login lacks sysadmin / SQLAgentReaderRole membership in msdb and can therefore only see jobs it owns. '
                     + N'Confirm the job inventory with an elevated login before concluding that failure alerting is not required.';
    END
    ELSE
    BEGIN
        SET @Pct = CAST((@Notified * 100.0) / @Total AS DECIMAL(5,1));

        IF @Notified = @Total AND @Operators > 0 AND @Profiles > 0 AND @DbMailXps = 1
            SET @Score = 3;
        ELSE IF @Notified = @Total
            SET @Score = 2;
        ELSE IF @Pct >= 80.0
            SET @Score = 2;
        ELSE IF @Notified > 0
            SET @Score = 1;
        ELSE
            SET @Score = 0;

        SET @Finding = CAST(@Notified AS NVARCHAR(20)) + N' of ' + CAST(@Total AS NVARCHAR(20))
                     + N' enabled SQL Server Agent job(s) (' + CAST(@Pct AS NVARCHAR(10))
                     + N'%) notify an enabled operator when the job fails. '
                     + N'Delivery path: Database Mail XPs = ' + CAST(@DbMailXps AS NVARCHAR(10))
                     + N', mail profiles = ' + CAST(@Profiles AS NVARCHAR(20))
                     + N', enabled operators with an email address = ' + CAST(@Operators AS NVARCHAR(20)) + N'. '
                     + CASE WHEN @Sample IS NOT NULL
                            THEN N'Jobs with no failure notification (first 5): ' + @Sample + N'. '
                            ELSE N'' END
                     + CASE WHEN @Notified = @Total AND (@DbMailXps <> 1 OR @Profiles = 0 OR @Operators = 0)
                            THEN N'All jobs are wired for notification but the delivery path is incomplete, so alerts may never leave the instance. '
                            ELSE N'' END
                     + N'Whether the notified operator address actually reaches the responsible on-call team must be confirmed against the support model.';
    END;
END;

DROP TABLE #JobNotify;
DROP TABLE #MailInfra;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;