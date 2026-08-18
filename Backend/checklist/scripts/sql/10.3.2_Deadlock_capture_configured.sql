-- Checklist: Deadlock capture configured
-- Scope: SERVER
-- Scoring: 0: No XE session for deadlocks. 1: Session exists but disabled. 2: Session enabled but missing xml_deadlock_report action or target. 3: Session enabled, captures deadlock_graph, has xml_deadlock_report action, and has a target.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @SessionExists BIT = 0;
DECLARE @SessionEnabled BIT = 0;
DECLARE @HasXmlAction BIT = 0;
DECLARE @HasTarget BIT = 0;
DECLARE @SessionName NVARCHAR(128) = '';

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: evaluate database-level XE sessions
    SELECT TOP 1 
        @SessionExists = 1,
        @SessionEnabled = xe_ses.is_enabled,
        @SessionName = xe_ses.name,
        @HasXmlAction = CASE WHEN EXISTS(
            SELECT 1 FROM sys.database_event_session_actions sea 
            JOIN sys.dm_xe_objects a ON sea.name = a.name AND a.object_type = 'action'
            WHERE sea.event_session_id = xe_ses.event_session_id AND a.name = 'xml_deadlock_report'
        ) THEN 1 ELSE 0 END,
        @HasTarget = CASE WHEN EXISTS(
            SELECT 1 FROM sys.database_event_session_targets tgt 
            WHERE tgt.event_session_id = xe_ses.event_session_id
        ) THEN 1 ELSE 0 END
    FROM sys.database_event_sessions xe_ses
    JOIN sys.database_event_session_events xe_see ON xe_ses.event_session_id = xe_see.event_session_id
    JOIN sys.dm_xe_objects xe_evt ON xe_see.event_name = xe_evt.name AND xe_evt.object_type = 'event'
    WHERE xe_evt.name = 'deadlock_graph'
    ORDER BY xe_ses.is_enabled DESC;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: evaluate server-level XE sessions
    SELECT TOP 1 
        @SessionExists = 1,
        @SessionEnabled = xe_ses.is_enabled,
        @SessionName = xe_ses.name,
        @HasXmlAction = CASE WHEN EXISTS(
            SELECT 1 FROM sys.server_event_session_actions sea 
            JOIN sys.dm_xe_objects a ON sea.name = a.name AND a.object_type = 'action'
            WHERE sea.session_id = xe_ses.session_id AND a.name = 'xml_deadlock_report'
        ) THEN 1 ELSE 0 END,
        @HasTarget = CASE WHEN EXISTS(
            SELECT 1 FROM sys.server_event_session_targets tgt 
            WHERE tgt.session_id = xe_ses.session_id
        ) THEN 1 ELSE 0 END
    FROM sys.server_event_sessions xe_ses
    JOIN sys.server_event_session_events xe_see ON xe_ses.session_id = xe_see.session_id
    JOIN sys.dm_xe_objects xe_evt ON xe_see.event_name = xe_evt.name AND xe_evt.object_type = 'event'
    WHERE xe_evt.name = 'deadlock_graph'
    ORDER BY xe_ses.is_enabled DESC;
END

SET @Score = 0;
SET @Finding = '';

IF @SessionExists = 0
BEGIN
    SET @Score = 0;
    SET @Finding = 'No Extended Event session configured for deadlock capture.';
END
ELSE IF @SessionEnabled = 0
BEGIN
    SET @Score = 1;
    SET @Finding = 'Deadlock capture session [' + @SessionName + '] exists but is disabled.';
END
ELSE IF @HasXmlAction = 1 AND @HasTarget = 1
BEGIN
    SET @Score = 3;
    SET @Finding = 'Deadlock capture session [' + @SessionName + '] is enabled, captures deadlock_graph, includes xml_deadlock_report action, and has a target configured.';
END
ELSE
BEGIN
    SET @Score = 2;
    SET @Finding = 'Deadlock capture session [' + @SessionName + '] is enabled but lacks xml_deadlock_report action or a target.';
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;