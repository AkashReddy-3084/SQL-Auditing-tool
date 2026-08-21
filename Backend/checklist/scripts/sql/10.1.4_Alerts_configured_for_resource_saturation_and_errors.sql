-- Checklist: Alerts configured for resource saturation and errors
-- Scope: SERVER
-- Scoring: 0: No relevant alerts configured. 1: Alerts exist but are disabled or lack operator notifications. 2: Partial coverage (only resource or only errors) or platform lacks SQL Agent. 3: Comprehensive alerts for both resource saturation and critical errors are configured, enabled, and assigned to operators.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

SET @DatabaseQueried = 'master';

IF @EngineEdition = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'SQL Server Agent is not available in Azure SQL Database. Manual verification of Azure Monitor/Log Analytics alerts is required.';
END
ELSE IF OBJECT_ID('msdb.dbo.sysalerts') IS NOT NULL
BEGIN
    DECLARE @ResourceAlerts INT = 0;
    DECLARE @ErrorAlerts INT = 0;
    DECLARE @DisabledAlerts INT = 0;
    DECLARE @NoOpAlerts INT = 0;

    SELECT 
        @ResourceAlerts = COUNT(CASE WHEN enabled = 1 AND has_notification = 1 AND (LOWER(name) LIKE '%disk%' OR LOWER(name) LIKE '%memory%' OR LOWER(name) LIKE '%cpu%' OR LOWER(name) LIKE '%space%') THEN 1 END),
        @ErrorAlerts = COUNT(CASE WHEN enabled = 1 AND has_notification = 1 AND (severity >= 19 OR LOWER(name) LIKE '%error%' OR LOWER(name) LIKE '%failure%') THEN 1 END),
        @DisabledAlerts = COUNT(CASE WHEN enabled = 0 THEN 1 END),
        @NoOpAlerts = COUNT(CASE WHEN enabled = 1 AND has_notification = 0 THEN 1 END)
    FROM msdb.dbo.sysalerts
    WHERE LOWER(name) LIKE '%disk%' OR LOWER(name) LIKE '%memory%' OR LOWER(name) LIKE '%cpu%' OR LOWER(name) LIKE '%space%' OR LOWER(name) LIKE '%error%' OR LOWER(name) LIKE '%failure%' OR severity >= 19;

    IF @ResourceAlerts > 0 AND @ErrorAlerts > 0
        SET @Score = 3;
    ELSE IF @ResourceAlerts > 0 OR @ErrorAlerts > 0
        SET @Score = 2;
    ELSE IF @DisabledAlerts > 0 OR @NoOpAlerts > 0
        SET @Score = 1;
    ELSE
        SET @Score = 0;

    SET @Finding = 'Resource alerts (enabled+operator): ' + CAST(@ResourceAlerts AS NVARCHAR(10)) + '; Error alerts (enabled+operator): ' + CAST(@ErrorAlerts AS NVARCHAR(10)) + '; Disabled: ' + CAST(@DisabledAlerts AS NVARCHAR(10)) + '; No operator: ' + CAST(@NoOpAlerts AS NVARCHAR(10));
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = 'SQL Server Agent alerts table (msdb.dbo.sysalerts) is inaccessible or unavailable.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;