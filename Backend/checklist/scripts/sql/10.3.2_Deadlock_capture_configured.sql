-- Checklist: Deadlock capture configured
-- Scope: SERVER
-- Scoring: 0=No capture configured, 1=Legacy Trace ID 12 enabled, 2=XE session exists but inactive, 3=Active XE session capturing deadlocks
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

-- Check for active Extended Event session capturing deadlocks
IF EXISTS (
    SELECT 1
    FROM sys.server_event_sessions ses
    INNER JOIN sys.dm_xe_sessions dxs ON ses.name = dxs.name
    INNER JOIN sys.event_session_events ese ON ses.address = ese.event_session_address
    WHERE ese.event_name IN ('xml_deadlock_report', 'deadlock_graph')
)
BEGIN
    SET @Score = 3;
END
ELSE IF EXISTS (
    SELECT 1
    FROM sys.server_event_sessions ses
    INNER JOIN sys.event_session_events ese ON ses.address = ese.event_session_address
    WHERE ese.event_name IN ('xml_deadlock_report', 'deadlock_graph')
)
BEGIN
    SET @Score = 2;
END
ELSE IF EXISTS (
    SELECT 1
    FROM sys.traces
    WHERE id = 12 AND is_default = 1
)
BEGIN
    SET @Score = 1;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;