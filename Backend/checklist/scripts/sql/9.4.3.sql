SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @ServerName NVARCHAR(128) = ISNULL(CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128)), N'(unknown)');
DECLARE @Result NVARCHAR(50);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(128);
DECLARE @Finding NVARCHAR(4000);

DECLARE @Metrics TABLE (MetricName NVARCHAR(64) NOT NULL, MetricValue INT NULL);

DECLARE @TotalAlerts INT = 0;
DECLARE @EnabledAlerts INT = 0;
DECLARE @EnabledAlertsWithNotification INT = 0;
DECLARE @EnabledSlaConditionAlerts INT = 0;
DECLARE @EnabledOperatorsWithEmail INT = 0;
DECLARE @DatabaseMailEnabled INT = 0;
DECLARE @MailProfiles INT = 0;

IF @EngineEdition = 5
BEGIN
    SET @DatabaseQueried = DB_NAME();
    SET @Score = 1;
    SET @Finding = N'Azure SQL Database (EngineEdition 5): SQL Server Agent alerts, operators and Database Mail do not exist in this deployment model, so SLA breach alerting cannot be evidenced from the engine. Confirm in the Azure portal that Azure Monitor alert rules and action groups are configured for the SLA metrics of this database (availability, DTU/vCore utilisation, storage, failed connections) and re-score manually.';
END
ELSE
BEGIN
    SET @DatabaseQueried = N'msdb';

    BEGIN TRY
        INSERT INTO @Metrics (MetricName, MetricValue)
        EXEC sp_executesql N'
            SELECT ''TotalAlerts'', COUNT(*) FROM msdb.dbo.sysalerts
            UNION ALL
            SELECT ''EnabledAlerts'', COUNT(*) FROM msdb.dbo.sysalerts WHERE enabled = 1
            UNION ALL
            SELECT ''EnabledAlertsWithNotification'', COUNT(DISTINCT a.id)
                FROM msdb.dbo.sysalerts AS a
                INNER JOIN msdb.dbo.sysnotifications AS n ON n.alert_id = a.id
                INNER JOIN msdb.dbo.sysoperators AS o ON o.id = n.operator_id
                WHERE a.enabled = 1 AND o.enabled = 1
            UNION ALL
            SELECT ''EnabledSlaConditionAlerts'', COUNT(*)
                FROM msdb.dbo.sysalerts
                WHERE enabled = 1
                  AND (performance_condition IS NOT NULL
                       OR severity >= 16
                       OR ISNULL(message_id, 0) > 0
                       OR wmi_query IS NOT NULL)
            UNION ALL
            SELECT ''EnabledOperatorsWithEmail'', COUNT(*)
                FROM msdb.dbo.sysoperators
                WHERE enabled = 1
                  AND email_address IS NOT NULL
                  AND LTRIM(RTRIM(email_address)) <> ''''
            UNION ALL
            SELECT ''DatabaseMailEnabled'', ISNULL((SELECT CONVERT(INT, c.value_in_use)
                                                    FROM sys.configurations AS c
                                                    WHERE c.name = ''Database Mail XPs''), 0)
            UNION ALL
            SELECT ''MailProfiles'', COUNT(*) FROM msdb.dbo.sysmail_profile;';

        SELECT @TotalAlerts                   = ISNULL(MAX(CASE WHEN MetricName = N'TotalAlerts' THEN MetricValue END), 0),
               @EnabledAlerts                 = ISNULL(MAX(CASE WHEN MetricName = N'EnabledAlerts' THEN MetricValue END), 0),
               @EnabledAlertsWithNotification = ISNULL(MAX(CASE WHEN MetricName = N'EnabledAlertsWithNotification' THEN MetricValue END), 0),
               @EnabledSlaConditionAlerts     = ISNULL(MAX(CASE WHEN MetricName = N'EnabledSlaConditionAlerts' THEN MetricValue END), 0),
               @EnabledOperatorsWithEmail     = ISNULL(MAX(CASE WHEN MetricName = N'EnabledOperatorsWithEmail' THEN MetricValue END), 0),
               @DatabaseMailEnabled           = ISNULL(MAX(CASE WHEN MetricName = N'DatabaseMailEnabled' THEN MetricValue END), 0),
               @MailProfiles                  = ISNULL(MAX(CASE WHEN MetricName = N'MailProfiles' THEN MetricValue END), 0)
        FROM @Metrics;

        IF @TotalAlerts = 0
        BEGIN
            SET @Score = 0;
            SET @Finding = N'No SQL Server Agent alerts are defined on instance ' + @ServerName
                + N'. An SLA breach (severity error, performance threshold or failure condition) would raise no automated notification to anyone.';
        END
        ELSE IF @EnabledAlertsWithNotification = 0
                OR @EnabledOperatorsWithEmail = 0
                OR @DatabaseMailEnabled = 0
                OR @MailProfiles = 0
        BEGIN
            SET @Score = 1;
            SET @Finding = N'The alert notification chain on instance ' + @ServerName + N' is broken: '
                + CAST(@TotalAlerts AS NVARCHAR(10)) + N' alert(s) defined, '
                + CAST(@EnabledAlerts AS NVARCHAR(10)) + N' enabled, '
                + CAST(@EnabledAlertsWithNotification AS NVARCHAR(10)) + N' enabled alert(s) wired to an enabled operator, '
                + CAST(@EnabledOperatorsWithEmail AS NVARCHAR(10)) + N' enabled operator(s) with an e-mail address, Database Mail XPs '
                + CASE WHEN @DatabaseMailEnabled = 1 THEN N'enabled' ELSE N'disabled' END + N', '
                + CAST(@MailProfiles AS NVARCHAR(10)) + N' Database Mail profile(s). An SLA breach would be logged but not delivered to an owner.';
        END
        ELSE IF @EnabledSlaConditionAlerts = 0
        BEGIN
            SET @Score = 2;
            SET @Finding = N'Alert delivery works on instance ' + @ServerName + N' ('
                + CAST(@EnabledAlertsWithNotification AS NVARCHAR(10)) + N' enabled alert(s) notify an enabled operator, '
                + CAST(@EnabledOperatorsWithEmail AS NVARCHAR(10)) + N' operator(s) with e-mail, Database Mail enabled with '
                + CAST(@MailProfiles AS NVARCHAR(10)) + N' profile(s)), but none of the enabled alerts covers an SLA-relevant condition: no performance-condition alert, no severity 16+ alert, no specific message-id alert and no WMI alert is defined.';
        END
        ELSE
        BEGIN
            SET @Score = 3;
            SET @Finding = N'SLA breach alerting is in place on instance ' + @ServerName + N': '
                + CAST(@EnabledSlaConditionAlerts AS NVARCHAR(10)) + N' enabled alert(s) cover SLA-relevant conditions, '
                + CAST(@EnabledAlertsWithNotification AS NVARCHAR(10)) + N' enabled alert(s) notify an enabled operator, '
                + CAST(@EnabledOperatorsWithEmail AS NVARCHAR(10)) + N' enabled operator(s) hold an e-mail address, Database Mail XPs is enabled and '
                + CAST(@MailProfiles AS NVARCHAR(10)) + N' Database Mail profile(s) are configured.';
        END
    END TRY
    BEGIN CATCH
        SET @Score = 1;
        SET @Finding = N'Unable to read the SQL Server Agent alerting configuration in msdb on instance ' + @ServerName + N': '
            + ISNULL(ERROR_MESSAGE(), N'(no error message returned)')
            + N' Re-run with a login holding SQLAgentReaderRole in msdb (and VIEW SERVER STATE) and verify SLA breach alerts manually.';
    END CATCH
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    CAST(@Result AS NVARCHAR(50))           AS Result,
    CAST(@Score AS INT)                     AS Score,
    CAST(@DatabaseQueried AS NVARCHAR(128)) AS DatabaseQueried,
    CAST(@Finding AS NVARCHAR(4000))        AS Finding;