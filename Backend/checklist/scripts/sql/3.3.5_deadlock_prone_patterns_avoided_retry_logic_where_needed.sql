SET NOCOUNT ON;
-- Check for Extended Events system_health session (deadlocks captured by system session)
SELECT CASE WHEN EXISTS(SELECT 1 FROM sys.server_event_sessions WHERE name = 'system_health') THEN 'Passed' ELSE 'NeedsReview' END AS Result;
