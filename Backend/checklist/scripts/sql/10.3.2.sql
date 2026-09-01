-- Checklist: Deadlock capture configured
-- Scope: SERVER
-- Scoring: 3 = a dedicated Extended Events session capturing deadlock events is running; 2 = system_health is running or a deadlock trace flag is globally enabled; 1 = a deadlock session is defined but stopped and nothing else captures; 0 = no deadlock capture at all

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Deadlock capture evidence could not be collected';
DECLARE @Engine INT = ISNULL(CONVERT(INT, SERVERPROPERTY('EngineEdition')), 0);
DECLARE @DedicatedRunning INT = 0;
DECLARE @DedicatedStopped INT = 0;
DECLARE @SystemHealthRunning INT = 0;
DECLARE @TraceFlags INT = 0;
DECLARE @TraceFlagList NVARCHAR(MAX) = 'none';
DECLARE @RunningList NVARCHAR(MAX) = 'none';
DECLARE @StoppedList NVARCHAR(MAX) = 'none';
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DeadlockSessions (SessionName NVARCHAR(128) NOT NULL, IsRunning INT NOT NULL);
CREATE TABLE #DeadlockTraceFlags (TraceFlag INT NULL, TraceStatus INT NULL, IsGlobal INT NULL, IsSession INT NULL);

BEGIN TRY
    SET @Sql = CASE WHEN @Engine = 5
        THEN N'SELECT DISTINCT s.name, CASE WHEN r.name IS NULL THEN 0 ELSE 1 END FROM sys.database_event_sessions AS s JOIN sys.database_event_session_events AS e ON e.event_session_id = s.event_session_id LEFT JOIN sys.dm_xe_database_sessions AS r ON r.name = s.name WHERE e.name LIKE ''%deadlock%'';'
        ELSE N'SELECT DISTINCT s.name, CASE WHEN r.name IS NULL THEN 0 ELSE 1 END FROM sys.server_event_sessions AS s JOIN sys.server_event_session_events AS e ON e.event_session_id = s.event_session_id LEFT JOIN sys.dm_xe_sessions AS r ON r.name = s.name WHERE e.name LIKE ''%deadlock%'';' END;
    INSERT INTO #DeadlockSessions (SessionName, IsRunning) EXEC sys.sp_executesql @Sql;
END TRY
BEGIN CATCH
    SET @Sql = NULL;
END CATCH;

IF @Engine <> 5
BEGIN
    BEGIN TRY
        INSERT INTO #DeadlockTraceFlags (TraceFlag, TraceStatus, IsGlobal, IsSession)
        EXEC ('DBCC TRACESTATUS(-1) WITH NO_INFOMSGS');
    END TRY
    BEGIN CATCH
        SET @Sql = NULL;
    END CATCH;
END

SELECT @DedicatedRunning = ISNULL(SUM(CASE WHEN IsRunning = 1 AND SessionName <> N'system_health' THEN 1 ELSE 0 END), 0),
       @DedicatedStopped = ISNULL(SUM(CASE WHEN IsRunning = 0 AND SessionName <> N'system_health' THEN 1 ELSE 0 END), 0),
       @SystemHealthRunning = ISNULL(SUM(CASE WHEN IsRunning = 1 AND SessionName = N'system_health' THEN 1 ELSE 0 END), 0)
FROM #DeadlockSessions;

SELECT @RunningList = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX), SessionName), ', '), 'none')
FROM #DeadlockSessions
WHERE IsRunning = 1;

SELECT @StoppedList = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX), SessionName), ', '), 'none')
FROM #DeadlockSessions
WHERE IsRunning = 0;

SELECT @TraceFlags = COUNT(*),
       @TraceFlagList = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX), TraceFlag), ', '), 'none')
FROM #DeadlockTraceFlags
WHERE TraceFlag IN (1204, 1222) AND TraceStatus = 1 AND IsGlobal = 1;

DROP TABLE #DeadlockSessions;
DROP TABLE #DeadlockTraceFlags;

SET @Score = CASE
    WHEN @DedicatedRunning > 0 THEN 3
    WHEN @SystemHealthRunning > 0 OR @TraceFlags > 0 THEN 2
    WHEN @DedicatedStopped > 0 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT('Running Extended Events sessions capturing deadlock events: ', @RunningList,
    ' (dedicated non-system_health running = ', @DedicatedRunning, ', system_health running = ', @SystemHealthRunning,
    '); defined but stopped deadlock sessions: ', @StoppedList,
    '; globally enabled deadlock trace flags: ', @TraceFlagList,
    CASE
        WHEN @DedicatedRunning > 0 THEN '. Deadlock graphs are retained by a dedicated session.'
        WHEN @SystemHealthRunning > 0 THEN '. Capture relies on the default system_health ring buffer, which recycles.'
        WHEN @TraceFlags > 0 THEN '. Capture relies on error-log trace flag output only.'
        WHEN @DedicatedStopped > 0 THEN '. A deadlock session exists but is not started, so nothing is being captured.'
        ELSE '. Nothing is capturing deadlock events on this instance.'
    END);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;