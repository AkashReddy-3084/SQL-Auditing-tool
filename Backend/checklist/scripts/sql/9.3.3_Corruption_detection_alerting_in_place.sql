USE master;
-- Checklist: Corruption detection alerting in place
-- Scope: SERVER
-- Scoring: 0=No corruption alerts found; 1=Alerts exist but notification disabled or no operator; 2=Alerts configured with operator notification enabled; 3=Multiple corruption alerts enabled with operator notification
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @AlertCount INT = 0;
DECLARE @NotifiedCount INT = 0;

IF OBJECT_ID('msdb.dbo.sysalerts') IS NOT NULL
BEGIN
    SELECT 
        @AlertCount = COUNT(*),
        @NotifiedCount = ISNULL(SUM(CASE WHEN enabled = 1 AND has_notification = 1 THEN 1 ELSE 0 END), 0)
    FROM msdb.dbo.sysalerts
    WHERE message_id IN (823, 824, 825) 
       OR message_id BETWEEN 8900 AND 8999;

    IF @AlertCount = 0
        SET @Score = 0;
    ELSE IF @NotifiedCount = 0
        SET @Score = 1;
    ELSE IF @NotifiedCount >= 3
        SET @Score = 3;
    ELSE
        SET @Score = 2;
END
ELSE
BEGIN
    SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;