-- Checklist: Error/severity alerts configured (Agent alerts or equivalent)
-- Scope: SERVER
-- Scoring: 0=No alerts found, 1=Alerts exist but disabled, 2=Alerts enabled but lack operator, 3=Alerts enabled and linked to operator.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

SELECT @Score = CASE 
    WHEN COUNT(*) = 0 THEN 0
    WHEN MAX(CASE WHEN enabled = 1 AND has_notification = 1 THEN 1 ELSE 0 END) = 1 THEN 3
    WHEN MAX(CASE WHEN enabled = 1 THEN 1 ELSE 0 END) = 1 THEN 2
    ELSE 1
END
FROM msdb.dbo.sysalerts
WHERE event_source_type IN (0, 1) AND event_source > 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;