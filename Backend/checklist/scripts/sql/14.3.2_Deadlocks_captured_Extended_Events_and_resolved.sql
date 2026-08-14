-- Checklist: Deadlocks captured (Extended Events) and resolved
-- Scope: SERVER
-- Scoring: 0 = No EE session capturing deadlocks; 1 = Session exists but disabled or lacks a target; 2 = Session enabled with target (capture verified); 3 = Capture verified + automated resolution evidence (capped at 2 due to human review requirement for "resolved")
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

IF OBJECT_ID('sys.server_event_sessions') IS NOT NULL
BEGIN
    IF EXISTS (
        SELECT 1
        FROM sys.server_event_sessions ses
        JOIN sys.server_event_session_events see ON ses.event_session_id = see.event_session_id
        WHERE see.event_name IN ('deadlock', 'deadlock_graph')
        AND ses.is_enabled = 1
        AND EXISTS (
            SELECT 1 FROM sys.server_event_session_targets setgt
            WHERE setgt.event_session_id = ses.event_session_id
        )
    )
        SET @Score = 2;
    ELSE IF EXISTS (
        SELECT 1
        FROM sys.server_event_sessions ses
        JOIN sys.server_event_session_events see ON ses.event_session_id = see.event_session_id
        WHERE see.event_name IN ('deadlock', 'deadlock_graph')
    )
        SET @Score = 1;
    ELSE
        SET @Score = 0;
END
ELSE
    SET @Score = 0;

-- NOTE: This script provides automated evidence. Full compliance requires human review.
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;