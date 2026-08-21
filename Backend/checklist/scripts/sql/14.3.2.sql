SET NOCOUNT ON;

/* Checklist 14.3.2 - Deadlocks captured (Extended Events) and resolved. Read-only. */

DECLARE @EngineEdition      INT             = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Result             NVARCHAR(20);
DECLARE @Score              INT             = 0;
DECLARE @Finding            NVARCHAR(4000)  = N'';
DECLARE @DatabaseQueried    NVARCHAR(128)   = ISNULL(DB_NAME(), N'master');
DECLARE @Sql                NVARCHAR(MAX);
DECLARE @MetadataReadable   BIT             = 1;
DECLARE @MetadataError      NVARCHAR(2000)  = N'';

DECLARE @Sessions TABLE
(
    SessionName SYSNAME NOT NULL,
    EventName   SYSNAME NOT NULL,
    IsRunning   BIT     NOT NULL
);

IF @EngineEdition = 5
BEGIN
    SET @Sql = N'SELECT es.name, ev.name, CASE WHEN rs.name IS NOT NULL THEN 1 ELSE 0 END
                 FROM sys.database_event_sessions AS es
                 INNER JOIN sys.database_event_session_events AS ev
                         ON ev.event_session_id = es.event_session_id
                 LEFT JOIN sys.dm_xe_database_sessions AS rs
                        ON rs.name = es.name
                 WHERE ev.name IN (N''xml_deadlock_report'', N''database_xml_deadlock_report'',
                                   N''lock_deadlock'', N''lock_deadlock_chain'');';
END
ELSE
BEGIN
    SET @Sql = N'SELECT es.name, ev.name, CASE WHEN rs.name IS NOT NULL THEN 1 ELSE 0 END
                 FROM sys.server_event_sessions AS es
                 INNER JOIN sys.server_event_session_events AS ev
                         ON ev.event_session_id = es.event_session_id
                 LEFT JOIN sys.dm_xe_sessions AS rs
                        ON rs.name = es.name
                 WHERE ev.name IN (N''xml_deadlock_report'', N''database_xml_deadlock_report'',
                                   N''lock_deadlock'', N''lock_deadlock_chain'');';
END

BEGIN TRY
    INSERT INTO @Sessions (SessionName, EventName, IsRunning)
    EXEC sp_executesql @Sql;
END TRY
BEGIN CATCH
    SET @MetadataReadable = 0;
    SET @MetadataError = LEFT(ERROR_MESSAGE(), 2000);
END CATCH

DECLARE @DefinedSessions     INT = 0;
DECLARE @RunningSessions     INT = 0;
DECLARE @RunningCustom       INT = 0;
DECLARE @SystemHealthRunning INT = 0;

SELECT  @DefinedSessions = COUNT(DISTINCT SessionName),
        @RunningSessions = COUNT(DISTINCT CASE WHEN IsRunning = 1 THEN SessionName END),
        @RunningCustom   = COUNT(DISTINCT CASE WHEN IsRunning = 1 AND SessionName <> N'system_health' THEN SessionName END),
        @SystemHealthRunning = COUNT(DISTINCT CASE WHEN IsRunning = 1 AND SessionName = N'system_health' THEN SessionName END)
FROM @Sessions;

DECLARE @SessionList NVARCHAR(2000) = N'';

SELECT @SessionList = @SessionList + s.SessionName
                    + N' (' + CASE WHEN s.IsRunning = 1 THEN N'running' ELSE N'stopped' END + N'), '
FROM (SELECT DISTINCT SessionName, IsRunning FROM @Sessions) AS s;

IF LEN(@SessionList) > 1
    SET @SessionList = LEFT(@SessionList, LEN(@SessionList) - 1);
ELSE
    SET @SessionList = N'none';

DECLARE @DeadlockCount BIGINT = NULL;

BEGIN TRY
    SELECT @DeadlockCount = MAX(CAST(pc.cntr_value AS BIGINT))
    FROM sys.dm_os_performance_counters AS pc
    WHERE RTRIM(pc.counter_name) = N'Number of Deadlocks/sec'
      AND RTRIM(pc.instance_name) = N'_Total';
END TRY
BEGIN CATCH
    SET @DeadlockCount = NULL;
END CATCH

IF @MetadataReadable = 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'Extended Events metadata could not be read (VIEW SERVER STATE / VIEW DATABASE STATE may be missing), so deadlock capture could not be confirmed. Error: '
                 + @MetadataError;
END
ELSE IF @DefinedSessions = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No Extended Events session subscribes to a deadlock event (xml_deadlock_report, database_xml_deadlock_report, lock_deadlock or lock_deadlock_chain). Deadlocks are not being captured.';
END
ELSE IF @RunningSessions = 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'Deadlock-capturing Extended Events session(s) are defined but none are running. Sessions found: '
                 + @SessionList + N'. No deadlock data is currently being collected.';
END
ELSE IF @DeadlockCount IS NULL OR @DeadlockCount = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'Deadlock capture is active. Running deadlock-capturing Extended Events session(s): '
                 + @SessionList
                 + N' (custom sessions running: ' + CAST(@RunningCustom AS NVARCHAR(10))
                 + N', system_health running: ' + CAST(@SystemHealthRunning AS NVARCHAR(10)) + N'). '
                 + CASE WHEN @DeadlockCount IS NULL
                        THEN N'The cumulative deadlock counter was not readable, but no outstanding deadlocks were detected.'
                        ELSE N'Cumulative deadlock count since instance start is 0, so there are no deadlocks awaiting resolution.'
                   END;
END
ELSE
BEGIN
    SET @Score = 2;
    SET @Finding = N'Deadlock capture is active via Extended Events session(s): ' + @SessionList
                 + N', but the instance has recorded ' + CAST(@DeadlockCount AS NVARCHAR(20))
                 + N' deadlock(s) since it was last started. Capture is in place; evidence that these deadlocks were investigated and resolved must be confirmed manually.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT  @Result          AS Result,
        @Score           AS Score,
        @DatabaseQueried AS DatabaseQueried,
        @Finding         AS Finding;