/* =============================================================================
   Checklist Item : 14.3.1 - Blocking monitored and root causes addressed
   Scope          : SERVER
   Supported      : SQL Server 2012+, Azure SQL Managed Instance, Azure SQL Database
   Safety         : STRICTLY READ-ONLY. No DDL, no DML, no configuration change.
   Output         : Result, Score, DatabaseQueried, Finding
   ============================================================================= */
SET NOCOUNT ON;

DECLARE @IsAzureSqlDb        BIT            = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @BlockedProcThresh   INT            = -1;   -- -1 means not readable on this edition
DECLARE @BpDefined           INT            = 0;    -- XE sessions defined with blocked_process_report
DECLARE @BpRunning           INT            = 0;    -- of those, currently running
DECLARE @DeadlockRunning     INT            = 0;    -- running deadlock capture excluding system_health
DECLARE @CaptureSessionList  NVARCHAR(1000) = NULL;
DECLARE @ActiveTraceCount    INT            = 0;
DECLARE @CurrentBlockedCount INT            = 0;
DECLARE @Sql                 NVARCHAR(MAX);
DECLARE @Score               INT;
DECLARE @Result              NVARCHAR(20);
DECLARE @Finding             NVARCHAR(4000);
DECLARE @DatabaseQueried     NVARCHAR(256);

SET @DatabaseQueried = CASE WHEN @IsAzureSqlDb = 1 THEN DB_NAME() ELSE N'N/A (Server-level)' END;

/* ---------- 1. Blocked process threshold ---------------------------------- */
IF OBJECT_ID('sys.configurations') IS NOT NULL
BEGIN
    SET @Sql = N'SELECT @thresh = TRY_CONVERT(INT, c.value_in_use)
                 FROM sys.configurations AS c
                 WHERE c.name = ''blocked process threshold (s)'';';
    BEGIN TRY
        EXEC sys.sp_executesql @Sql, N'@thresh INT OUTPUT', @thresh = @BlockedProcThresh OUTPUT;
    END TRY
    BEGIN CATCH
        SET @BlockedProcThresh = -1;
    END CATCH
END

SET @BlockedProcThresh = COALESCE(@BlockedProcThresh, -1);

/* ---------- 2. Extended Events capture sessions ---------------------------- */
IF @IsAzureSqlDb = 1
BEGIN
    SET @Sql = N'
    SELECT @bpDefined = COUNT(DISTINCT s.name)
    FROM sys.database_event_sessions AS s
    INNER JOIN sys.database_event_session_events AS e ON e.event_session_id = s.event_session_id
    WHERE e.name = ''blocked_process_report'';

    SELECT @bpRunning = COUNT(DISTINCT s.name)
    FROM sys.database_event_sessions AS s
    INNER JOIN sys.database_event_session_events AS e ON e.event_session_id = s.event_session_id
    INNER JOIN sys.dm_xe_database_sessions AS x ON x.name = s.name
    WHERE e.name = ''blocked_process_report'';

    SELECT @dlRunning = COUNT(DISTINCT s.name)
    FROM sys.database_event_sessions AS s
    INNER JOIN sys.database_event_session_events AS e ON e.event_session_id = s.event_session_id
    INNER JOIN sys.dm_xe_database_sessions AS x ON x.name = s.name
    WHERE e.name IN (''xml_deadlock_report'', ''lock_deadlock'', ''lock_deadlock_chain'')
      AND s.name <> ''system_health'';

    SELECT @list = STUFF((
        SELECT N'', '' + d.name
        FROM (
            SELECT DISTINCT s2.name
            FROM sys.database_event_sessions AS s2
            INNER JOIN sys.database_event_session_events AS e2 ON e2.event_session_id = s2.event_session_id
            INNER JOIN sys.dm_xe_database_sessions AS x2 ON x2.name = s2.name
            WHERE e2.name IN (''blocked_process_report'', ''xml_deadlock_report'', ''lock_deadlock'', ''lock_deadlock_chain'')
        ) AS d
        ORDER BY d.name
        FOR XML PATH(''''), TYPE).value(''.'', ''NVARCHAR(1000)''), 1, 2, N'''');';
END
ELSE
BEGIN
    SET @Sql = N'
    SELECT @bpDefined = COUNT(DISTINCT s.name)
    FROM sys.server_event_sessions AS s
    INNER JOIN sys.server_event_session_events AS e ON e.event_session_id = s.event_session_id
    WHERE e.name = ''blocked_process_report'';

    SELECT @bpRunning = COUNT(DISTINCT s.name)
    FROM sys.server_event_sessions AS s
    INNER JOIN sys.server_event_session_events AS e ON e.event_session_id = s.event_session_id
    INNER JOIN sys.dm_xe_sessions AS x ON x.name = s.name
    WHERE e.name = ''blocked_process_report'';

    SELECT @dlRunning = COUNT(DISTINCT s.name)
    FROM sys.server_event_sessions AS s
    INNER JOIN sys.server_event_session_events AS e ON e.event_session_id = s.event_session_id
    INNER JOIN sys.dm_xe_sessions AS x ON x.name = s.name
    WHERE e.name IN (''xml_deadlock_report'', ''lock_deadlock'', ''lock_deadlock_chain'')
      AND s.name <> ''system_health'';

    SELECT @list = STUFF((
        SELECT N'', '' + d.name
        FROM (
            SELECT DISTINCT s2.name
            FROM sys.server_event_sessions AS s2
            INNER JOIN sys.server_event_session_events AS e2 ON e2.event_session_id = s2.event_session_id
            INNER JOIN sys.dm_xe_sessions AS x2 ON x2.name = s2.name
            WHERE e2.name IN (''blocked_process_report'', ''xml_deadlock_report'', ''lock_deadlock'', ''lock_deadlock_chain'')
        ) AS d
        ORDER BY d.name
        FOR XML PATH(''''), TYPE).value(''.'', ''NVARCHAR(1000)''), 1, 2, N'''');';
END

BEGIN TRY
    EXEC sys.sp_executesql @Sql,
         N'@bpDefined INT OUTPUT, @bpRunning INT OUTPUT, @dlRunning INT OUTPUT, @list NVARCHAR(1000) OUTPUT',
         @bpDefined = @BpDefined       OUTPUT,
         @bpRunning = @BpRunning       OUTPUT,
         @dlRunning = @DeadlockRunning OUTPUT,
         @list      = @CaptureSessionList OUTPUT;
END TRY
BEGIN CATCH
    SET @BpDefined       = 0;
    SET @BpRunning       = 0;
    SET @DeadlockRunning = 0;
END CATCH

SET @BpDefined       = COALESCE(@BpDefined, 0);
SET @BpRunning       = COALESCE(@BpRunning, 0);
SET @DeadlockRunning = COALESCE(@DeadlockRunning, 0);

/* ---------- 3. Active non-default server-side traces ----------------------- */
IF OBJECT_ID('sys.traces') IS NOT NULL
BEGIN
    SET @Sql = N'SELECT @cnt = COUNT(*) FROM sys.traces AS t WHERE t.is_default = 0 AND t.status = 1;';
    BEGIN TRY
        EXEC sys.sp_executesql @Sql, N'@cnt INT OUTPUT', @cnt = @ActiveTraceCount OUTPUT;
    END TRY
    BEGIN CATCH
        SET @ActiveTraceCount = 0;
    END CATCH
END

SET @ActiveTraceCount = COALESCE(@ActiveTraceCount, 0);

/* ---------- 4. Supporting evidence: blocking happening right now ----------- */
BEGIN TRY
    SELECT @CurrentBlockedCount = COUNT(*)
    FROM sys.dm_exec_requests AS r
    WHERE r.blocking_session_id <> 0
      AND r.session_id <> @@SPID;
END TRY
BEGIN CATCH
    SET @CurrentBlockedCount = -1;   -- permission denied on the DMV
END CATCH

SET @CurrentBlockedCount = COALESCE(@CurrentBlockedCount, -1);

/* ---------- 5. Scoring ----------------------------------------------------- */
DECLARE @ThresholdSet BIT = CASE WHEN @BlockedProcThresh > 0 THEN 1 ELSE 0 END;
DECLARE @CaptureLive  BIT = CASE WHEN @BpRunning > 0 THEN 1 ELSE 0 END;

IF @ThresholdSet = 1 AND @CaptureLive = 1
    SET @Score = 3;
ELSE IF @ThresholdSet = 1 OR @CaptureLive = 1
    SET @Score = 2;
ELSE IF @BpDefined > 0 OR @DeadlockRunning > 0 OR @ActiveTraceCount > 0
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score = 3 THEN N'Pass' ELSE N'Fail' END;

/* ---------- 6. Finding ----------------------------------------------------- */
SET @Finding =
      N'Blocked process threshold (s): '
    + CASE WHEN @BlockedProcThresh < 0 THEN N'not readable on this edition'
           WHEN @BlockedProcThresh = 0 THEN N'0 (disabled - blocked process reports are never raised)'
           ELSE CONVERT(NVARCHAR(20), @BlockedProcThresh) + N' second(s)' END
    + N'. XE sessions capturing blocked_process_report: ' + CONVERT(NVARCHAR(20), @BpDefined)
    + N' defined, ' + CONVERT(NVARCHAR(20), @BpRunning) + N' running.'
    + N' Running deadlock/blocking capture sessions excluding system_health: ' + CONVERT(NVARCHAR(20), @DeadlockRunning)
    + N'. Active non-default server-side traces: ' + CONVERT(NVARCHAR(20), @ActiveTraceCount)
    + N'.'
    + CASE WHEN @CaptureSessionList IS NOT NULL
           THEN N' Running capture session(s): ' + @CaptureSessionList + N'.'
           ELSE N'' END
    + CASE WHEN @CurrentBlockedCount < 0
           THEN N' Live blocking could not be sampled (insufficient permission on sys.dm_exec_requests).'
           ELSE N' Requests blocked at the moment of sampling: ' + CONVERT(NVARCHAR(20), @CurrentBlockedCount) + N'.' END
    + CASE @Score
        WHEN 3 THEN N' Blocking monitoring is configured and active: the threshold is set and a session is capturing blocked_process_report. Evidence that identified root causes were actually remediated is a process artifact and should be confirmed against incident/change records.'
        WHEN 2 THEN N' Blocking monitoring is only partially configured - either the threshold is set with nothing capturing the report, or a capture session is running while the threshold is 0 so the event can never fire.'
        WHEN 1 THEN N' No effective blocked_process_report monitoring is active; only partial evidence (a stopped capture session, a deadlock-only session, or a custom trace) was found.'
        ELSE N' No blocking monitoring evidence was found: the blocked process threshold is not enabled and no Extended Events session or trace captures blocking or deadlock events.'
      END;

/* ---------- 7. Standard four-column output --------------------------------- */
SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;