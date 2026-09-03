SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @DatabaseQueried NVARCHAR(128) = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 5 THEN DB_NAME() ELSE N'master' END;
DECLARE @HasPerm BIT = CASE WHEN HAS_PERMS_BY_NAME(NULL, NULL, N'VIEW SERVER STATE') = 1 THEN 1 ELSE 0 END;
DECLARE @CollectError BIT = 0;
DECLARE @TraceError BIT = 0;
DECLARE @sql NVARCHAR(MAX);

IF OBJECT_ID(N'tempdb..#XeSessions') IS NOT NULL DROP TABLE #XeSessions;
CREATE TABLE #XeSessions
(
    SessionName NVARCHAR(256) NOT NULL,
    IsRunning   BIT           NOT NULL
);

IF OBJECT_ID(N'tempdb..#LegacyTraces') IS NOT NULL DROP TABLE #LegacyTraces;
CREATE TABLE #LegacyTraces
(
    TraceId     INT NOT NULL,
    TraceStatus INT NULL
);

IF @EngineEdition = 5
    SET @sql = N'SELECT es.name, CASE WHEN xs.name IS NOT NULL THEN 1 ELSE 0 END
                 FROM sys.database_event_sessions AS es
                 LEFT JOIN sys.dm_xe_database_sessions AS xs ON xs.name = es.name;';
ELSE
    SET @sql = N'SELECT es.name, CASE WHEN xs.name IS NOT NULL THEN 1 ELSE 0 END
                 FROM sys.server_event_sessions AS es
                 LEFT JOIN sys.dm_xe_sessions AS xs ON xs.name = es.name;';

BEGIN TRY
    INSERT INTO #XeSessions (SessionName, IsRunning)
    EXEC sp_executesql @sql;
END TRY
BEGIN CATCH
    SET @CollectError = 1;
END CATCH

IF @EngineEdition <> 5
BEGIN
    SET @sql = N'SELECT t.id, t.status FROM sys.traces AS t WHERE t.is_default = 0;';

    BEGIN TRY
        INSERT INTO #LegacyTraces (TraceId, TraceStatus)
        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
        SET @TraceError = 1;
    END CATCH
END

DECLARE @UserSessionCount INT =
(
    SELECT COUNT(*)
    FROM #XeSessions
    WHERE SessionName NOT IN (N'system_health', N'AlwaysOn_health', N'telemetry_xevents', N'sp_server_diagnostics session', N'hkenginexesession')
);

DECLARE @UserRunningCount INT =
(
    SELECT COUNT(*)
    FROM #XeSessions
    WHERE IsRunning = 1
      AND SessionName NOT IN (N'system_health', N'AlwaysOn_health', N'telemetry_xevents', N'sp_server_diagnostics session', N'hkenginexesession')
);

DECLARE @LegacyTraceCount INT = (SELECT COUNT(*) FROM #LegacyTraces);
DECLARE @RunningTraceCount INT = (SELECT COUNT(*) FROM #LegacyTraces WHERE TraceStatus = 1);

DECLARE @UserSessionNames NVARCHAR(2000) =
(
    STUFF
    (
        (
            SELECT N', ' + x.SessionName
            FROM #XeSessions AS x
            WHERE x.SessionName NOT IN (N'system_health', N'AlwaysOn_health', N'telemetry_xevents', N'sp_server_diagnostics session', N'hkenginexesession')
            ORDER BY x.SessionName
            FOR XML PATH(N''), TYPE
        ).value(N'.', N'NVARCHAR(2000)'), 1, 2, N''
    )
);

DECLARE @RunningSessionNames NVARCHAR(2000) =
(
    STUFF
    (
        (
            SELECT N', ' + x.SessionName
            FROM #XeSessions AS x
            WHERE x.IsRunning = 1
              AND x.SessionName NOT IN (N'system_health', N'AlwaysOn_health', N'telemetry_xevents', N'sp_server_diagnostics session', N'hkenginexesession')
            ORDER BY x.SessionName
            FOR XML PATH(N''), TYPE
        ).value(N'.', N'NVARCHAR(2000)'), 1, 2, N''
    )
);

DECLARE @RunningTraceIds NVARCHAR(1000) =
(
    STUFF
    (
        (
            SELECT N', ' + CAST(t.TraceId AS NVARCHAR(20))
            FROM #LegacyTraces AS t
            WHERE t.TraceStatus = 1
            ORDER BY t.TraceId
            FOR XML PATH(N''), TYPE
        ).value(N'.', N'NVARCHAR(1000)'), 1, 2, N''
    )
);

SET @UserSessionNames = ISNULL(@UserSessionNames, N'none');
SET @RunningSessionNames = ISNULL(@RunningSessionNames, N'none');
SET @RunningTraceIds = ISNULL(@RunningTraceIds, N'none');

DECLARE @Result NVARCHAR(20);
DECLARE @Score INT;
DECLARE @Finding NVARCHAR(4000);

IF @HasPerm = 0 OR @CollectError = 1
BEGIN
    SET @Score = 1;
    SET @Finding = N'Extended Events metadata could not be read (VIEW SERVER STATE permission missing or catalog query failed). Manual verification of diagnostic tracing is required.';
END
ELSE IF @UserRunningCount >= 1 AND @RunningTraceCount = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'Diagnostics use Extended Events: ' + CAST(@UserRunningCount AS NVARCHAR(10)) + N' user-defined XE session(s) running (' + @RunningSessionNames + N') out of ' + CAST(@UserSessionCount AS NVARCHAR(10)) + N' defined, and no non-default SQL Trace is running.';
END
ELSE IF @UserSessionCount >= 1 AND @RunningTraceCount > 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'Partial: ' + CAST(@UserSessionCount AS NVARCHAR(10)) + N' user-defined XE session(s) defined (' + @UserSessionNames + N'), ' + CAST(@UserRunningCount AS NVARCHAR(10)) + N' running, but ' + CAST(@RunningTraceCount AS NVARCHAR(10)) + N' deprecated SQL Trace(s) are still running (trace id(s): ' + @RunningTraceIds + N').';
END
ELSE IF @UserSessionCount >= 1
BEGIN
    SET @Score = 2;
    SET @Finding = N'Partial: ' + CAST(@UserSessionCount AS NVARCHAR(10)) + N' user-defined XE session(s) are defined (' + @UserSessionNames + N') but none is currently running, so no Extended Events diagnostics are actively being captured.';
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = N'No user-defined Extended Events sessions exist (only built-in sessions such as system_health were found)' + CASE WHEN @LegacyTraceCount > 0 THEN N' while ' + CAST(@LegacyTraceCount AS NVARCHAR(10)) + N' non-default SQL Trace(s) are configured, ' + CAST(@RunningTraceCount AS NVARCHAR(10)) + N' of them running.' ELSE N' and no diagnostic tracing is configured at all.' END;
END

IF @TraceError = 1
    SET @Finding = @Finding + N' Note: sys.traces could not be queried, so deprecated Profiler traces were not assessed.';

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

IF OBJECT_ID(N'tempdb..#XeSessions') IS NOT NULL DROP TABLE #XeSessions;
IF OBJECT_ID(N'tempdb..#LegacyTraces') IS NOT NULL DROP TABLE #LegacyTraces;

SELECT
    @Result           AS Result,
    @Score            AS Score,
    @DatabaseQueried  AS DatabaseQueried,
    @Finding          AS Finding;