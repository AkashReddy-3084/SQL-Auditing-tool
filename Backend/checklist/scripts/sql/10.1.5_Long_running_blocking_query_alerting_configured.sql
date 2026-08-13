-- Checklist: Long-running/blocking query alerting configured
-- Scope: SERVER
-- Scoring: 0=No evidence, 1=Alert/EE exists but no notification, 2=Alerting configured with notification (indirect/generic) or EE session only, 3=Explicit blocking/long-running alert with valid operator notification
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @AlertCount INT = 0;
DECLARE @EECount INT = 0;
DECLARE @OperatorCount INT = 0;
DECLARE @NotificationCount INT = 0;

-- Check SQL Agent Alerts for blocking/long-running queries
IF EXISTS (SELECT 1 FROM msdb.dbo.sysalerts)
BEGIN
    SELECT @AlertCount = COUNT(*) FROM msdb.dbo.sysalerts
    WHERE name LIKE '%block%' OR name LIKE '%long%' OR name LIKE '%run%' OR name LIKE '%wait%'
       OR message_id IN (1222, 1205, 1223);
END

-- Check Extended Events for blocking/long-running queries
IF EXISTS (SELECT 1 FROM sys.server_event_sessions)
BEGIN
    SELECT @EECount = COUNT(DISTINCT ses.event_session_id)
    FROM sys.server_event_sessions ses
    INNER JOIN sys.server_event_session_events see ON ses.event_session_id = see.event_session_id
    INNER JOIN sys.server_events se ON see.event_id = se.event_id
    WHERE se.name IN ('blocked_process_report', 'lock_deadlock', 'sql_statement_completed', 'wait_info');
END

-- Check for enabled notification operators
IF EXISTS (SELECT 1 FROM msdb.dbo.sysoperators)
BEGIN
    SELECT @OperatorCount = COUNT(*) FROM msdb.dbo.sysoperators
    WHERE enabled = 1 AND (email_address IS NOT NULL OR pager IS NOT NULL);
END

-- Check if alerts are linked to operators
IF EXISTS (SELECT 1 FROM msdb.dbo.sysnotifications)
BEGIN
    SELECT @NotificationCount = COUNT(*) FROM msdb.dbo.sysnotifications
    WHERE alert_id IN (SELECT alert_id FROM msdb.dbo.sysalerts WHERE name LIKE '%block%' OR name LIKE '%long%');
END

-- Scoring Logic
IF @AlertCount > 0 AND @OperatorCount > 0 AND @NotificationCount > 0
    SET @Score = 3;
ELSE IF @EECount > 0 OR (@AlertCount > 0 AND @NotificationCount > 0)
    SET @Score = 2;
ELSE IF @AlertCount > 0 OR @EECount > 0
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;