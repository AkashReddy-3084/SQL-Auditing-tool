DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

DECLARE @XEventsConfigured INT = (SELECT COUNT(*) FROM sys.server_event_sessions);
DECLARE @XEventsActive INT = (SELECT COUNT(*) FROM sys.dm_xe_sessions WHERE name <> 'system_health');
DECLARE @ProfilerTraces INT = (SELECT COUNT(*) FROM sys.traces WHERE is_default = 0);

IF @XEventsConfigured = 0 AND @XEventsActive = 0
    SET @Score = 0;
ELSE IF @ProfilerTraces > 0
    SET @Score = 1;
ELSE IF @XEventsActive = 0
    SET @Score = 1;
ELSE IF @XEventsActive = 1
    SET @Score = 2;
ELSE
    SET @Score = 3;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score;