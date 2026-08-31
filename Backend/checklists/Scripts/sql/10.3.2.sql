SET NOCOUNT ON;

/* 10.3.2 - Deadlock capture configured (read-only) */

IF OBJECT_ID('tempdb..#DeadlockSessions') IS NOT NULL DROP TABLE #DeadlockSessions;
CREATE TABLE #DeadlockSessions
(
    SessionName SYSNAME     NOT NULL,
    IsRunning   BIT         NOT NULL
);

IF OBJECT_ID('tempdb..#TraceFlags') IS NOT NULL DROP TABLE #TraceFlags;
CREATE TABLE #TraceFlags
(
    TraceFlag   INT NULL,
    Status      INT NULL,
    Global      INT NULL,
    [Session]   INT NULL
);

DECLARE @EngineEdition   INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Sql             NVARCHAR(MAX);

/* Extended Events sessions that capture deadlock events */
IF @EngineEdition = 5   /* Azure SQL Database - database-scoped XE only */
BEGIN
    SET @Sql = N'
        SELECT DISTINCT
               s.name,
               CASE WHEN r.name IS NOT NULL THEN 1 ELSE 0 END
        FROM sys.database_event_sessions AS s
        INNER JOIN sys.database_event_session_events AS e
                ON e.event_session_id = s.event_session_id
        LEFT JOIN sys.dm_xe_database_sessions AS r
                ON r.name = s.name
        WHERE e.name IN (N''xml_deadlock_report'', N''database_xml_deadlock_report'',
                         N''lock_deadlock'', N''lock_deadlock_chain'');';

    BEGIN TRY
        INSERT INTO #DeadlockSessions (SessionName, IsRunning)
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        /* metadata not visible - leave set empty */
    END CATCH
END
ELSE
BEGIN
    SET @Sql = N'
        SELECT DISTINCT
               s.name,
               CASE WHEN r.name IS NOT NULL THEN 1 ELSE 0 END
        FROM sys.server_event_sessions AS s
        INNER JOIN sys.server_event_session_events AS e
                ON e.event_session_id = s.event_session_id
        LEFT JOIN sys.dm_xe_sessions AS r
                ON r.name = s.name
        WHERE e.name IN (N''xml_deadlock_report'', N''lock_deadlock'', N''lock_deadlock_chain'');';

    BEGIN TRY
        INSERT INTO #DeadlockSessions (SessionName, IsRunning)
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        /* metadata not visible - leave set empty */
    END CATCH

    /* Deadlock trace flags 1222 / 1204 */
    BEGIN TRY
        INSERT INTO #TraceFlags (TraceFlag, Status, Global, [Session])
        EXEC ('DBCC TRACESTATUS(-1) WITH NO_INFOMSGS');
    END TRY
    BEGIN CATCH
        /* DBCC TRACESTATUS unavailable (e.g. insufficient permission) - treat as none */
    END CATCH
END

DECLARE @DedicatedRunning   INT = ISNULL((SELECT COUNT(*) FROM #DeadlockSessions
                                          WHERE IsRunning = 1 AND SessionName <> N'system_health'), 0);
DECLARE @DedicatedStopped   INT = ISNULL((SELECT COUNT(*) FROM #DeadlockSessions
                                          WHERE IsRunning = 0 AND SessionName <> N'system_health'), 0);
DECLARE @SystemHealthRuns   INT = ISNULL((SELECT COUNT(*) FROM #DeadlockSessions
                                          WHERE IsRunning = 1 AND SessionName = N'system_health'), 0);
DECLARE @SystemHealthExists INT = ISNULL((SELECT COUNT(*) FROM #DeadlockSessions
                                          WHERE SessionName = N'system_health'), 0);
DECLARE @TfGlobalCount      INT = ISNULL((SELECT COUNT(*) FROM #TraceFlags
                                          WHERE TraceFlag IN (1222, 1204) AND Status = 1 AND Global = 1), 0);

DECLARE @RunningList NVARCHAR(1000) = ISNULL(STUFF((
        SELECT N', ' + SessionName
        FROM #DeadlockSessions
        WHERE IsRunning = 1
        ORDER BY SessionName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(1000)'), 1, 2, N''), N'none');

DECLARE @StoppedList NVARCHAR(1000) = ISNULL(STUFF((
        SELECT N', ' + SessionName
        FROM #DeadlockSessions
        WHERE IsRunning = 0
        ORDER BY SessionName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(1000)'), 1, 2, N''), N'none');

DECLARE @TfList NVARCHAR(200) = ISNULL(STUFF((
        SELECT N', ' + CAST(TraceFlag AS NVARCHAR(10))
        FROM #TraceFlags
        WHERE TraceFlag IN (1222, 1204) AND Status = 1 AND Global = 1
        ORDER BY TraceFlag
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(200)'), 1, 2, N''), N'none');

DECLARE @Result  NVARCHAR(20);
DECLARE @Score   INT;
DECLARE @Finding NVARCHAR(MAX);

IF @DedicatedRunning > 0
   OR (@SystemHealthRuns > 0 AND @TfGlobalCount > 0)
    SET @Score = 3;
ELSE IF @SystemHealthRuns > 0 OR @DedicatedStopped > 0 OR @TfGlobalCount > 0
    SET @Score = 2;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding =
      N'Deadlock capture assessment on '
    + QUOTENAME(CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(256)))
    + N' (EngineEdition ' + CAST(@EngineEdition AS NVARCHAR(10)) + N'). '
    + N'Running XE sessions capturing deadlock events: ' + @RunningList + N'. '
    + N'Defined but stopped deadlock XE sessions: ' + @StoppedList + N'. '
    + N'Dedicated (non-system_health) running sessions: ' + CAST(@DedicatedRunning AS NVARCHAR(10)) + N'. '
    + N'system_health session '
    + CASE WHEN @SystemHealthRuns > 0 THEN N'is running'
           WHEN @SystemHealthExists > 0 THEN N'exists but is stopped'
           ELSE N'not detected as capturing deadlock events' END + N'. '
    + N'Globally enabled deadlock trace flags (1222/1204): ' + @TfList + N'. '
    + CASE
        WHEN @Score = 3 AND @DedicatedRunning > 0
            THEN N'A dedicated Extended Events session is actively capturing xml_deadlock_report, so deadlock graphs are retained beyond the system_health ring buffer.'
        WHEN @Score = 3
            THEN N'system_health is running and a deadlock trace flag is globally enabled, so deadlock graphs are captured to both the XE ring buffer and the SQL Server error log.'
        WHEN @Score = 2 AND @SystemHealthRuns > 0 AND @DedicatedRunning = 0 AND @TfGlobalCount = 0
            THEN N'Only the default system_health session captures deadlocks; its ring buffer is memory-resident and recycles, so older deadlock graphs are lost.'
        WHEN @Score = 2 AND @DedicatedStopped > 0
            THEN N'A deadlock Extended Events session is defined but not running, so no deadlock graphs are currently being collected by it.'
        WHEN @Score = 2
            THEN N'Deadlock trace flags are enabled without a running Extended Events deadlock session, so capture relies solely on error-log text output.'
        ELSE N'No Extended Events session captures deadlock events and neither trace flag 1222 nor 1204 is globally enabled, so deadlocks are not being recorded.'
      END;

SELECT
    @Result  AS Result,
    @Score   AS Score,
    CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(256)) AS DatabaseQueried,
    @Finding AS Finding;

IF OBJECT_ID('tempdb..#DeadlockSessions') IS NOT NULL DROP TABLE #DeadlockSessions;
IF OBJECT_ID('tempdb..#TraceFlags') IS NOT NULL DROP TABLE #TraceFlags;