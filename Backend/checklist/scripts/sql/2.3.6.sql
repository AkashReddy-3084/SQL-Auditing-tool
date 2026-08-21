/*==============================================================================
 Checklist Item : 2.3.6 - Failures trigger notifications (email/alert/monitoring)
 Area           : Data Integration & ETL
 Scope          : SERVER (SQL Server Agent / msdb metadata)
 Mode           : READ-ONLY - catalog metadata SELECTs only, no DDL/DML
 Output         : Result, Score, DatabaseQueried, Finding
==============================================================================*/
SET NOCOUNT ON;

DECLARE @EngineEdition      INT            = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Result             NVARCHAR(20)   = N'Fail';
DECLARE @Score              INT            = 0;
DECLARE @DatabaseQueried    NVARCHAR(256)  = N'msdb';
DECLARE @Finding            NVARCHAR(4000) = N'';

DECLARE @TotalJobs          INT = 0;
DECLARE @EnabledJobs        INT = 0;
DECLARE @JobsFailNotify     INT = 0;
DECLARE @JobsEventLogOnly   INT = 0;
DECLARE @EnabledOperators   INT = 0;
DECLARE @OperatorsWithEmail INT = 0;
DECLARE @AlertsWithNotify   INT = 0;
DECLARE @MailProfiles       INT = 0;
DECLARE @MailXpEnabled      INT = 0;
DECLARE @Coverage           DECIMAL(5,1) = 0;
DECLARE @ErrMsg             NVARCHAR(2000) = NULL;
DECLARE @MailErr            NVARCHAR(2000) = NULL;
DECLARE @sql                NVARCHAR(MAX);

SELECT @MailXpEnabled = CONVERT(INT, ISNULL(c.value_in_use, 0))
FROM sys.configurations AS c
WHERE c.name = 'Database Mail XPs';

IF @EngineEdition = 5
BEGIN
    SET @DatabaseQueried = DB_NAME();
    SET @Score   = 0;
    SET @Finding = N'Azure SQL Database (EngineEdition 5) does not expose SQL Server Agent or msdb, so ETL failure notification cannot be evaluated from T-SQL. Failure alerting for data integration on this platform is configured outside the database engine (Azure Data Factory / Synapse pipeline alerts, Elastic Jobs, Azure Monitor action groups, Log Analytics rules) and must be verified manually.';
END
ELSE IF DB_ID('msdb') IS NULL
BEGIN
    SET @Score   = 0;
    SET @Finding = N'The msdb database is not present or not visible on this instance (EngineEdition ' + CONVERT(NVARCHAR(10), @EngineEdition) + N'), so SQL Server Agent job failure notification settings cannot be inspected. Verify the ETL orchestration platform''s alerting configuration manually.';
END
ELSE
BEGIN
    /* Three-part msdb names stay inside dynamic SQL so the batch still parses where msdb is absent. */
    BEGIN TRY
        SET @sql = N'
        SELECT @pTotal        = COUNT(*),
               @pEnabled      = ISNULL(SUM(CASE WHEN j.enabled = 1 THEN 1 ELSE 0 END), 0),
               @pFailNotify   = ISNULL(SUM(CASE WHEN j.enabled = 1
                                                 AND (j.notify_level_email   IN (2,3)
                                                   OR j.notify_level_page    IN (2,3)
                                                   OR j.notify_level_netsend IN (2,3))
                                                THEN 1 ELSE 0 END), 0),
               @pEventLogOnly = ISNULL(SUM(CASE WHEN j.enabled = 1
                                                 AND j.notify_level_eventlog IN (2,3)
                                                 AND j.notify_level_email    NOT IN (2,3)
                                                 AND j.notify_level_page     NOT IN (2,3)
                                                 AND j.notify_level_netsend  NOT IN (2,3)
                                                THEN 1 ELSE 0 END), 0)
        FROM msdb.dbo.sysjobs AS j;

        SELECT @pOps      = ISNULL(SUM(CASE WHEN o.enabled = 1 THEN 1 ELSE 0 END), 0),
               @pOpsEmail = ISNULL(SUM(CASE WHEN o.enabled = 1
                                             AND NULLIF(LTRIM(RTRIM(o.email_address)), N'''') IS NOT NULL
                                            THEN 1 ELSE 0 END), 0)
        FROM msdb.dbo.sysoperators AS o;

        SELECT @pAlerts = ISNULL(SUM(CASE WHEN a.enabled = 1 AND a.has_notification > 0 THEN 1 ELSE 0 END), 0)
        FROM msdb.dbo.sysalerts AS a;';

        EXEC sys.sp_executesql
             @sql,
             N'@pTotal INT OUTPUT, @pEnabled INT OUTPUT, @pFailNotify INT OUTPUT, @pEventLogOnly INT OUTPUT, @pOps INT OUTPUT, @pOpsEmail INT OUTPUT, @pAlerts INT OUTPUT',
             @pTotal        = @TotalJobs          OUTPUT,
             @pEnabled      = @EnabledJobs        OUTPUT,
             @pFailNotify   = @JobsFailNotify     OUTPUT,
             @pEventLogOnly = @JobsEventLogOnly   OUTPUT,
             @pOps          = @EnabledOperators   OUTPUT,
             @pOpsEmail     = @OperatorsWithEmail OUTPUT,
             @pAlerts       = @AlertsWithNotify   OUTPUT;
    END TRY
    BEGIN CATCH
        SET @ErrMsg = ERROR_MESSAGE();
    END CATCH

    /* Database Mail profile metadata is restricted to DatabaseMailUserRole; isolate it. */
    BEGIN TRY
        SET @sql = N'SELECT @pProfiles = COUNT(*) FROM msdb.dbo.sysmail_profile;';
        EXEC sys.sp_executesql @sql, N'@pProfiles INT OUTPUT', @pProfiles = @MailProfiles OUTPUT;
    END TRY
    BEGIN CATCH
        SET @MailProfiles = 0;
        SET @MailErr = ERROR_MESSAGE();
    END CATCH

    IF @ErrMsg IS NOT NULL
    BEGIN
        SET @Score   = 0;
        SET @Finding = N'SQL Server Agent notification metadata in msdb could not be read by the audit login. Error: ' + @ErrMsg + N' Grant SQLAgentReaderRole (or equivalent) in msdb and re-run, or verify job failure notifications manually.';
    END
    ELSE IF @TotalJobs = 0
    BEGIN
        SET @Score   = 0;
        SET @Finding = N'No SQL Server Agent jobs are defined (or visible to this login) in msdb.dbo.sysjobs, so ETL failure notification cannot be assessed from Agent metadata. Database Mail XPs enabled = ' + CONVERT(NVARCHAR(10), @MailXpEnabled) + N', Database Mail profiles = ' + CONVERT(NVARCHAR(10), @MailProfiles) + N', enabled operators = ' + CONVERT(NVARCHAR(10), @EnabledOperators) + N', enabled alerts with notifications = ' + CONVERT(NVARCHAR(10), @AlertsWithNotify) + N'. If data integration is orchestrated externally (ADF, SSIS Catalog scheduler, third-party scheduler), verify its failure alerting manually.';
    END
    ELSE IF @EnabledJobs = 0
    BEGIN
        SET @Score   = 0;
        SET @Finding = CONVERT(NVARCHAR(10), @TotalJobs) + N' SQL Server Agent job(s) exist but none are enabled, so no active data integration schedule could be evaluated for failure notification. Database Mail XPs enabled = ' + CONVERT(NVARCHAR(10), @MailXpEnabled) + N', Database Mail profiles = ' + CONVERT(NVARCHAR(10), @MailProfiles) + N', enabled operators with an email address = ' + CONVERT(NVARCHAR(10), @OperatorsWithEmail) + N'. Manual review required.';
    END
    ELSE
    BEGIN
        SET @Coverage = CAST((@JobsFailNotify * 100.0) / @EnabledJobs AS DECIMAL(5,1));

        IF @Coverage >= 90.0
           AND @MailXpEnabled = 1
           AND @MailProfiles > 0
           AND @OperatorsWithEmail > 0
            SET @Score = 3;
        ELSE IF @Coverage >= 50.0
             OR (@JobsFailNotify > 0 AND @AlertsWithNotify > 0)
            SET @Score = 2;
        ELSE
            SET @Score = 1;

        SET @Finding =
              CONVERT(NVARCHAR(10), @JobsFailNotify) + N' of ' + CONVERT(NVARCHAR(10), @EnabledJobs)
            + N' enabled SQL Server Agent job(s) (' + CONVERT(NVARCHAR(10), @Coverage)
            + N'%) are configured to notify an operator on failure via email/pager/net send; '
            + CONVERT(NVARCHAR(10), @TotalJobs) + N' job(s) defined in total. '
            + CONVERT(NVARCHAR(10), @JobsEventLogOnly) + N' enabled job(s) write to the Windows event log on failure but send no operator notification. '
            + N'Database Mail XPs enabled = ' + CONVERT(NVARCHAR(10), @MailXpEnabled)
            + N', Database Mail profiles = ' + CONVERT(NVARCHAR(10), @MailProfiles)
            + N', enabled operators = ' + CONVERT(NVARCHAR(10), @EnabledOperators)
            + N' (with email address = ' + CONVERT(NVARCHAR(10), @OperatorsWithEmail)
            + N'), enabled alerts with notifications = ' + CONVERT(NVARCHAR(10), @AlertsWithNotify) + N'.'
            + CASE WHEN @MailErr IS NOT NULL
                   THEN N' Database Mail profile metadata was not readable by this login (' + @MailErr + N'), so the profile count may understate the configuration.'
                   ELSE N'' END
            + CASE WHEN @Score = 3 THEN N' Failure notification is configured end to end.'
                   WHEN @Score = 2 THEN N' Failure notification is only partially configured across the job estate or the delivery chain (Database Mail profile / operator email) is incomplete.'
                   ELSE N' Most enabled jobs fail silently - no operator notification and no compensating alert notification is configured.' END;
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;