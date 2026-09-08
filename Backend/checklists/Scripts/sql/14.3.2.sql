-- Checklist: Deadlocks captured (Extended Events) and resolved
-- Scope: SERVER
-- Scoring: 3 = a running Extended Events session captures deadlock events and no deadlocks are recorded; 2 = a running capture session exists but deadlocks have been recorded; 1 = a deadlock capture session is defined but not running, or deadlocks were recorded with no capture session; 0 = no deadlock capture session and no deadlock evidence

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Deadlock capture evidence could not be read';
DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Defined INT = 0;
DECLARE @Running INT = 0;
DECLARE @Deadlocks BIGINT = 0;
DECLARE @RunningNames NVARCHAR(MAX) = '';
DECLARE @DefinedNames NVARCHAR(MAX) = '';
DECLARE @XeRead BIT = 0;

DECLARE @Xe TABLE (SessionName NVARCHAR(128) NOT NULL, IsRunning INT NOT NULL);

-- Event-session metadata views differ between Azure SQL Database and the box/MI engines,
-- so the probe is issued through read-only dynamic SQL to stay parse-safe on both.
BEGIN TRY
    SET @Sql = CASE WHEN @Edition = 5 THEN
        N'SELECT DISTINCT es.name,
                 CASE WHEN EXISTS (SELECT 1 FROM sys.dm_xe_database_sessions AS r WHERE r.name = es.name)
                      THEN 1 ELSE 0 END
          FROM sys.database_event_sessions AS es
          JOIN sys.database_event_session_events AS ev ON ev.event_session_id = es.event_session_id
          WHERE ev.name LIKE ''%deadlock%'';'
      ELSE
        N'SELECT DISTINCT es.name,
                 CASE WHEN EXISTS (SELECT 1 FROM sys.dm_xe_sessions AS r WHERE r.name = es.name)
                      THEN 1 ELSE 0 END
          FROM sys.server_event_sessions AS es
          JOIN sys.server_event_session_events AS ev ON ev.event_session_id = es.event_session_id
          WHERE ev.name LIKE ''%deadlock%'';'
      END;

    INSERT INTO @Xe (SessionName, IsRunning)
    EXEC sys.sp_executesql @Sql;

    SET @XeRead = 1;
END TRY
BEGIN CATCH
    SET @XeRead = 0;
END CATCH;

SELECT @Defined = COUNT(*),
       @Running = ISNULL(SUM(IsRunning), 0)
FROM @Xe;

SELECT @RunningNames = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), SessionName), ', '), 300), 'none')
FROM @Xe
WHERE IsRunning = 1;

SELECT @DefinedNames = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), SessionName), ', '), 300), 'none')
FROM @Xe;

BEGIN TRY
    SET @Sql = N'SELECT @c = ISNULL(SUM(CONVERT(BIGINT, cntr_value)), 0)
                 FROM sys.dm_os_performance_counters
                 WHERE counter_name LIKE ''Number of Deadlocks/sec%'' AND instance_name = ''_Total'';';
    EXEC sys.sp_executesql @Sql, N'@c BIGINT OUTPUT', @c = @Deadlocks OUTPUT;
END TRY
BEGIN CATCH
    SET @Deadlocks = 0;
END CATCH;

SET @Deadlocks = ISNULL(@Deadlocks, 0);

SET @Score = CASE
    WHEN @XeRead = 0 THEN 0
    WHEN @Running > 0 AND @Deadlocks = 0 THEN 3
    WHEN @Running > 0 THEN 2
    WHEN @Defined > 0 OR @Deadlocks > 0 THEN 1
    ELSE 0
END;

SET @Finding = CASE
    WHEN @XeRead = 0
        THEN 'Extended Events session metadata could not be read on this instance; deadlock capture state is unknown'
    ELSE CONCAT(
        'deadlock capture sessions defined = ', @Defined, ' (', @DefinedNames, ')',
        '; running = ', @Running, ' (', @RunningNames, ')',
        '; cumulative deadlocks recorded by the engine = ', @Deadlocks)
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
