-- Checklist: Escalation path defined for critical alerts
-- Scope: SERVER
-- Scoring: 0: No operators or alerts with notifications. 1: Notifications enabled but no delay/escalation timing. 2: Notifications with delay_between_responses > 0 or multiple operators. 3: Critical alerts have notifications, delay > 0, and multiple operators linked.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT;
DECLARE @OperatorCount INT;
DECLARE @AlertsWithNotif INT;
DECLARE @AlertsWithDelay INT;
DECLARE @AlertsWithMultiOp INT;

SET @EngineEdition = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
SET @DatabaseQueried = 'master';

IF @EngineEdition = 5
BEGIN
    SET @Score = 1;
    SET @Finding = 'SQL Server Agent is not available in Azure SQL Database. Escalation paths must be defined via external monitoring or platform alerting rules.';
END
ELSE
BEGIN
    SELECT @OperatorCount = ISNULL(COUNT(*), 0) FROM msdb.dbo.sysoperators;
    
    SELECT @AlertsWithNotif = ISNULL(COUNT(*), 0) 
    FROM msdb.dbo.sysalerts 
    WHERE has_notification = 1;
    
    SELECT @AlertsWithDelay = ISNULL(COUNT(*), 0) 
    FROM msdb.dbo.sysalerts 
    WHERE has_notification = 1 AND delay_between_responses > 0;
    
    SELECT @AlertsWithMultiOp = ISNULL(COUNT(*), 0)
    FROM (
        SELECT a.alert_id
        FROM msdb.dbo.sysalerts a
        INNER JOIN msdb.dbo.sysalert_operator ao ON a.alert_id = ao.alert_id
        GROUP BY a.alert_id
        HAVING COUNT(ao.operator_id) > 1
    ) AS MultiOpAlerts;

    IF @OperatorCount = 0 OR @AlertsWithNotif = 0
        SET @Score = 0;
    ELSE IF @AlertsWithDelay = 0 AND @AlertsWithMultiOp = 0
        SET @Score = 1;
    ELSE IF @AlertsWithDelay > 0 OR @AlertsWithMultiOp > 0
        SET @Score = 2;
    ELSE
        SET @Score = 3;

    SET @Finding = 'Operators: ' + CAST(@OperatorCount AS NVARCHAR(10)) + '; Alerts with notifications: ' + CAST(@AlertsWithNotif AS NVARCHAR(10)) + '; Alerts with response delay: ' + CAST(@AlertsWithDelay AS NVARCHAR(10)) + '; Alerts linked to multiple operators: ' + CAST(@AlertsWithMultiOp AS NVARCHAR(10));
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;