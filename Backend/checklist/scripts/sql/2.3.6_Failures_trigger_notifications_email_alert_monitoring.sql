-- Checklist: Failures trigger notifications (email/alert/monitoring)
-- Scope: SERVER
-- Scoring: 3=Mail enabled & >=90% jobs notify on failure; 2=Mail enabled & >=50% notify OR mail disabled but operators configured OR Azure SQL DB; 1=Mail disabled & some jobs have operators; 0=No failure notifications configured.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @MailEnabled BIT = 0;
DECLARE @TotalJobs INT = 0;
DECLARE @NotifyingJobs INT = 0;
DECLARE @OperatorJobs INT = 0;

SET @DatabaseQueried = 'master';

IF @EngineEdition = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database does not support SQL Agent jobs. External monitoring/alerting must be verified manually.';
END
ELSE
BEGIN
    BEGIN TRY
        SELECT @MailEnabled = CONVERT(BIT, value_in_use)
        FROM sys.configurations
        WHERE name = 'Database Mail XPs';

        SELECT 
            @TotalJobs = COUNT(*),
            @NotifyingJobs = SUM(CASE WHEN notify_level_email >= 2 AND notify_operator_id > 0 THEN 1 ELSE 0 END),
            @OperatorJobs = SUM(CASE WHEN notify_operator_id > 0 THEN 1 ELSE 0 END)
        FROM msdb.dbo.sysjobs;
    END TRY
    BEGIN CATCH
        SET @MailEnabled = 0;
        SET @TotalJobs = 0;
        SET @NotifyingJobs = 0;
        SET @OperatorJobs = 0;
    END CATCH;

    IF @TotalJobs = 0
    BEGIN
        SET @Score = 2;
        SET @Finding = 'No SQL Agent jobs found. Database Mail is ' + CASE WHEN @MailEnabled = 1 THEN 'enabled' ELSE 'disabled' END + '.';
    END
    ELSE
    BEGIN
        DECLARE @NotifyPct FLOAT = CAST(@NotifyingJobs AS FLOAT) / @TotalJobs * 100;
        
        IF @MailEnabled = 1 AND @NotifyPct >= 90
            SET @Score = 3;
        ELSE IF @MailEnabled = 1 AND @NotifyPct >= 50
            SET @Score = 2;
        ELSE IF @MailEnabled = 0 AND @OperatorJobs > 0
            SET @Score = 2;
        ELSE IF @MailEnabled = 0 AND @OperatorJobs > 0 AND @NotifyPct > 0
            SET @Score = 1;
        ELSE IF @MailEnabled = 1 AND @NotifyPct > 0
            SET @Score = 1;
        ELSE
            SET @Score = 0;

        SET @Finding = 'Total jobs: ' + CAST(@TotalJobs AS NVARCHAR(10)) + 
                      ', Notifying on failure: ' + CAST(@NotifyingJobs AS NVARCHAR(10)) + 
                      ' (' + CAST(ROUND(@NotifyPct, 0) AS NVARCHAR(10)) + '%). ' +
                      'Database Mail: ' + CASE WHEN @MailEnabled = 1 THEN 'Enabled' ELSE 'Disabled' END + '.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;