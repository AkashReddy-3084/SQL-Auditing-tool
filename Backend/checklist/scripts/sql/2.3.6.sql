-- Checklist: Failures trigger notifications (email/alert/monitoring)
-- Scope: SERVER
-- Scoring: 3 = every enabled Agent job notifies on failure and a deliverable operator or mail profile exists; 2 = 75% or more of enabled jobs notify, or no jobs but notified alerts/operators exist, or Azure SQL Database; 1 = partial notification coverage or notification infrastructure only; 0 = no job notifies and no operator, mail profile or notified alert exists

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'SQL Agent notification metadata could not be read';
DECLARE @Engine INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Jobs INT = 0;
DECLARE @Notified INT = 0;
DECLARE @Operators INT = 0;
DECLARE @MailProfiles INT = 0;
DECLARE @Alerts INT = 0;
DECLARE @Missing NVARCHAR(MAX) = '';
DECLARE @ProbeError NVARCHAR(400) = '';
DECLARE @Coverage DECIMAL(9, 4) = 0;
DECLARE @Sql NVARCHAR(MAX);

IF @Engine = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database (EngineEdition 5): SQL Agent, Database Mail and alert metadata do not exist on this engine, so failure notification is raised by the external orchestrator or Azure Monitor and cannot be read from the instance.';
END
ELSE
BEGIN
    BEGIN TRY
        SET @Sql = N'
SELECT @j = COUNT(*),
       @n = ISNULL(SUM(CASE WHEN (j.notify_level_email >= 2 AND j.notify_email_operator_id > 0)
                              OR (j.notify_level_page >= 2 AND j.notify_page_operator_id > 0)
                              OR j.notify_level_eventlog >= 2 THEN 1 ELSE 0 END), 0),
       @m = ISNULL(LEFT(STRING_AGG(CASE WHEN (j.notify_level_email >= 2 AND j.notify_email_operator_id > 0)
                              OR (j.notify_level_page >= 2 AND j.notify_page_operator_id > 0)
                              OR j.notify_level_eventlog >= 2 THEN NULL
                              ELSE CONVERT(NVARCHAR(MAX), j.name) END, N'', ''), 400), N'''')
FROM msdb.dbo.sysjobs AS j
WHERE j.enabled = 1;';
        EXEC sys.sp_executesql @Sql,
             N'@j INT OUTPUT, @n INT OUTPUT, @m NVARCHAR(MAX) OUTPUT',
             @j = @Jobs OUTPUT, @n = @Notified OUTPUT, @m = @Missing OUTPUT;
    END TRY
    BEGIN CATCH
        SET @ProbeError = ERROR_MESSAGE();
    END CATCH

    BEGIN TRY
        SET @Sql = N'
SELECT @o = (SELECT COUNT(*) FROM msdb.dbo.sysoperators WHERE enabled = 1 AND email_address IS NOT NULL),
       @p = (SELECT COUNT(*) FROM msdb.dbo.sysmail_profile),
       @a = (SELECT COUNT(*) FROM msdb.dbo.sysalerts WHERE enabled = 1 AND has_notification > 0);';
        EXEC sys.sp_executesql @Sql,
             N'@o INT OUTPUT, @p INT OUTPUT, @a INT OUTPUT',
             @o = @Operators OUTPUT, @p = @MailProfiles OUTPUT, @a = @Alerts OUTPUT;
    END TRY
    BEGIN CATCH
        SET @ProbeError = ERROR_MESSAGE();
    END CATCH

    SET @Coverage = CASE WHEN @Jobs = 0 THEN 0
                         ELSE CONVERT(DECIMAL(9, 4), @Notified) / @Jobs END;

    IF @Jobs > 0 AND @Notified = @Jobs AND (@Operators > 0 OR @MailProfiles > 0)
        SET @Score = 3;
    ELSE IF @Jobs > 0 AND @Coverage >= 0.75
        SET @Score = 2;
    ELSE IF @Jobs = 0 AND (@Alerts > 0 OR @Operators > 0)
        SET @Score = 2;
    ELSE IF @Notified > 0 OR @Alerts > 0 OR @Operators > 0 OR @MailProfiles > 0
        SET @Score = 1;
    ELSE
        SET @Score = 0;

    SET @Finding = CONCAT('Enabled SQL Agent jobs = ', @Jobs,
        '; jobs raising a failure notification = ', @Notified,
        '; enabled operators with an email address = ', @Operators,
        '; Database Mail profiles = ', @MailProfiles,
        '; enabled alerts with a notification = ', @Alerts,
        CASE WHEN LEN(ISNULL(@Missing, '')) > 0
             THEN CONCAT('. Jobs with no failure notification: ', @Missing)
             ELSE '. No enabled job is missing a failure notification' END, '.',
        CASE WHEN LEN(@ProbeError) > 0 THEN CONCAT(' Agent metadata probe error: ', @ProbeError) ELSE '' END);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
