-- Checklist: Error/severity alerts configured (Agent alerts or equivalent)
-- Scope: SERVER
-- Scoring: 0: No error/severity alerts found. 1: Alerts exist but are disabled or lack operator notifications. 2: At least one alert enabled with operator notification. 3: Two or more alerts enabled with operator notifications.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @AlertCount INT = 0;
DECLARE @EnabledWithOperatorCount INT = 0;

IF @EngineEdition <> 5 AND OBJECT_ID('msdb.dbo.sysalerts') IS NOT NULL
BEGIN
    SELECT 
        @AlertCount = COUNT(*),
        @EnabledWithOperatorCount = SUM(CASE WHEN a.enabled = 1 AND EXISTS (SELECT 1 FROM msdb.dbo.sysnotifications n WHERE n.alert_id = a.id) THEN 1 ELSE 0 END)
    FROM msdb.dbo.sysalerts a
    WHERE a.message_id > 0 OR a.severity > 0;

    -- Fix: Handle NULL from SUM() when no rows match the CASE condition
    SET @EnabledWithOperatorCount = ISNULL(@EnabledWithOperatorCount, 0);

    IF @AlertCount = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No error/severity alerts configured.';
    END
    ELSE IF @EnabledWithOperatorCount = 0
    BEGIN
        SET @Score = 1;
        SET @Finding = CAST(@AlertCount AS NVARCHAR) + ' alert(s) found, but none are enabled or have operator notifications.';
    END
    ELSE IF @EnabledWithOperatorCount = 1
    BEGIN
        SET @Score = 2;
        SET @Finding = CAST(@EnabledWithOperatorCount AS NVARCHAR) + ' enabled alert(s) with operator notification(s) configured.';
    END
    ELSE
    BEGIN
        SET @Score = 3;
        SET @Finding = CAST(@EnabledWithOperatorCount AS NVARCHAR) + ' enabled alert(s) with operator notification(s) configured.';
    END
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = 'SQL Agent alerts not available on this platform/edition. Manual review required for equivalent monitoring.';
    -- NOTE: This script provides automated evidence. Full compliance requires human review.
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;