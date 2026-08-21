/*=====================================================================================
  Checklist Item : 14.4.5 - Memory grants monitored (no excessive spills to tempdb)
  Scope          : SERVER
  Access         : READ-ONLY. Catalog views, DMVs and Extended Events metadata only.
                   No DDL, no DML, no configuration change. Temp table used for staging.
  Output         : Result | Score | DatabaseQueried | Finding
=====================================================================================*/
SET NOCOUNT ON;

DECLARE @EngineEdition  INT            = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @ScopeName      NVARCHAR(256)  = ISNULL(CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(256)),
                                                CAST(@@SERVERNAME AS NVARCHAR(256)));
DECLARE @Result         NVARCHAR(20);
DECLARE @Score          INT            = 0;
DECLARE @Finding        NVARCHAR(4000) = N'';

/* ---- Thresholds ------------------------------------------------------------- */
DECLARE @MaxSemWaitMsPerHour BIGINT = 60000;   /* 60s RESOURCE_SEMAPHORE wait per hour of uptime */

/* ---- Collected facts -------------------------------------------------------- */
DECLARE @UptimeHours      DECIMAL(18,2) = NULL;
DECLARE @SemWaitMs        BIGINT = 0;
DECLARE @SemWaitTasks     BIGINT = 0;
DECLARE @CompileWaitMs    BIGINT = 0;
DECLARE @TimeoutErrors    BIGINT = 0;
DECLARE @ForcedGrants     BIGINT = 0;
DECLARE @CurrentWaiters   BIGINT = 0;
DECLARE @ActiveGrants     INT    = 0;
DECLARE @QueuedGrants     INT    = 0;
DECLARE @MaxGrantWaitMs   BIGINT = 0;
DECLARE @ActiveMonitors   INT    = 0;
DECLARE @DefinedMonitors  INT    = 0;
DECLARE @MonitorNames     NVARCHAR(1000) = NULL;
DECLARE @SemWaitMsPerHour BIGINT = 0;
DECLARE @XeChecked        BIT    = 1;
DECLARE @Supported        BIT    = 1;
DECLARE @PressureDetected BIT    = 0;
DECLARE @PressureDetail   NVARCHAR(1000) = N'';
DECLARE @MonitorDetail    NVARCHAR(1200) = N'';

/* Azure Synapse (dedicated / serverless) does not expose the memory grant DMVs. */
IF @EngineEdition IN (6, 11)
BEGIN
    SET @Supported = 0;
    SET @Score     = 0;
    SET @Finding   = N'Engine edition ' + CAST(@EngineEdition AS NVARCHAR(10))
                   + N' (Azure Synapse Analytics) does not expose sys.dm_exec_query_resource_semaphores or '
                   + N'sys.dm_exec_query_memory_grants. Memory grant monitoring and tempdb spill activity could not be '
                   + N'verified automatically and require manual review.';
END;

CREATE TABLE #MemoryGrantMonitors
(
    SessionName SYSNAME NOT NULL,
    IsRunning   BIT     NOT NULL
);

IF @Supported = 1
BEGIN
    BEGIN TRY

        /* -- 1. Instance uptime, used to normalise cumulative wait statistics ------ */
        SELECT @UptimeHours = CAST(DATEDIFF(MINUTE, si.sqlserver_start_time, SYSDATETIME()) / 60.0 AS DECIMAL(18,2))
        FROM sys.dm_os_sys_info AS si;

        /* -- 2. Cumulative memory grant waits ------------------------------------- */
        SELECT
            @SemWaitMs     = ISNULL(SUM(CASE WHEN ws.wait_type = N'RESOURCE_SEMAPHORE'
                                             THEN CAST(ws.wait_time_ms AS BIGINT) END), 0),
            @SemWaitTasks  = ISNULL(SUM(CASE WHEN ws.wait_type = N'RESOURCE_SEMAPHORE'
                                             THEN CAST(ws.waiting_tasks_count AS BIGINT) END), 0),
            @CompileWaitMs = ISNULL(SUM(CASE WHEN ws.wait_type = N'RESOURCE_SEMAPHORE_QUERY_COMPILE'
                                             THEN CAST(ws.wait_time_ms AS BIGINT) END), 0)
        FROM sys.dm_os_wait_stats AS ws
        WHERE ws.wait_type IN (N'RESOURCE_SEMAPHORE', N'RESOURCE_SEMAPHORE_QUERY_COMPILE');

        /* -- 3. Resource semaphore health (timeouts / forced grants) --------------- */
        SELECT
            @TimeoutErrors  = ISNULL(SUM(CAST(rs.timeout_error_count AS BIGINT)), 0),
            @ForcedGrants   = ISNULL(SUM(CAST(rs.forced_grant_count  AS BIGINT)), 0),
            @CurrentWaiters = ISNULL(SUM(CAST(rs.waiter_count        AS BIGINT)), 0)
        FROM sys.dm_exec_query_resource_semaphores AS rs;

        /* -- 4. Grants currently in flight / queued -------------------------------- */
        SELECT
            @ActiveGrants   = COUNT(*),
            @QueuedGrants   = ISNULL(SUM(CASE WHEN mg.grant_time IS NULL THEN 1 ELSE 0 END), 0),
            @MaxGrantWaitMs = ISNULL(MAX(CAST(mg.wait_time_ms AS BIGINT)), 0)
        FROM sys.dm_exec_query_memory_grants AS mg;

        /* -- 5. Extended Events coverage for spills / memory grants ---------------- */
        BEGIN TRY
            DECLARE @EventList NVARCHAR(1000) =
                N'''sort_warning'',''hash_warning'',''hash_spill_details'',''sort_spill_details'','
              + N'''exchange_spill'',''query_memory_grant_usage'',''query_memory_grant_blocking'','
              + N'''memory_grant_updated_by_feedback'',''memory_grant_feedback_loop_disabled''';
            DECLARE @Sql NVARCHAR(MAX);

            IF @EngineEdition = 5   /* Azure SQL Database: database-scoped XE metadata */
                SET @Sql = N'
SELECT DISTINCT s.name, CAST(1 AS BIT)
FROM sys.dm_xe_database_sessions AS s
INNER JOIN sys.dm_xe_database_session_events AS e
        ON e.event_session_address = s.address
WHERE e.name IN (' + @EventList + N')
UNION
SELECT DISTINCT es.name, CAST(0 AS BIT)
FROM sys.database_event_sessions AS es
INNER JOIN sys.database_event_session_events AS ese
        ON ese.event_session_id = es.event_session_id
WHERE ese.name IN (' + @EventList + N')
  AND NOT EXISTS (SELECT 1 FROM sys.dm_xe_database_sessions AS r WHERE r.name = es.name);';
            ELSE                    /* Box product and Azure SQL Managed Instance */
                SET @Sql = N'
SELECT DISTINCT s.name, CAST(1 AS BIT)
FROM sys.dm_xe_sessions AS s
INNER JOIN sys.dm_xe_session_events AS e
        ON e.event_session_address = s.address
WHERE e.name IN (' + @EventList + N')
UNION
SELECT DISTINCT es.name, CAST(0 AS BIT)
FROM sys.server_event_sessions AS es
INNER JOIN sys.server_event_session_events AS ese
        ON ese.event_session_id = es.event_session_id
WHERE ese.name IN (' + @EventList + N')
  AND NOT EXISTS (SELECT 1 FROM sys.dm_xe_sessions AS r WHERE r.name = es.name);';

            INSERT INTO #MemoryGrantMonitors (SessionName, IsRunning)
            EXEC sys.sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            SET @XeChecked = 0;   /* XE metadata not readable - monitoring coverage undetermined */
        END CATCH;

        SELECT
            @ActiveMonitors  = ISNULL(SUM(CASE WHEN m.IsRunning = 1 THEN 1 ELSE 0 END), 0),
            @DefinedMonitors = ISNULL(SUM(CASE WHEN m.IsRunning = 0 THEN 1 ELSE 0 END), 0)
        FROM #MemoryGrantMonitors AS m;

        SELECT @MonitorNames = STUFF((SELECT N', ' + m.SessionName
                                      FROM #MemoryGrantMonitors AS m
                                      WHERE m.IsRunning = 1
                                      ORDER BY m.SessionName
                                      FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(1000)'), 1, 2, N'');

        /* -- 6. Evaluate memory grant pressure ------------------------------------ */
        SET @SemWaitMsPerHour = CASE WHEN ISNULL(@UptimeHours, 0) > 0
                                     THEN CAST(@SemWaitMs / @UptimeHours AS BIGINT)
                                     ELSE @SemWaitMs END;

        IF @TimeoutErrors > 0
        BEGIN
            SET @PressureDetected = 1;
            SET @PressureDetail = @PressureDetail + N'grant timeout errors=' + CAST(@TimeoutErrors AS NVARCHAR(20)) + N'; ';
        END;

        IF @ForcedGrants > 0
        BEGIN
            SET @PressureDetected = 1;
            SET @PressureDetail = @PressureDetail + N'forced (reduced) grants=' + CAST(@ForcedGrants AS NVARCHAR(20)) + N'; ';
        END;

        IF @QueuedGrants > 0
        BEGIN
            SET @PressureDetected = 1;
            SET @PressureDetail = @PressureDetail + N'queries currently queued for memory=' + CAST(@QueuedGrants AS NVARCHAR(20))
                                + N' (max wait ' + CAST(@MaxGrantWaitMs AS NVARCHAR(20)) + N' ms); ';
        END;

        IF @SemWaitMsPerHour > @MaxSemWaitMsPerHour
        BEGIN
            SET @PressureDetected = 1;
            SET @PressureDetail = @PressureDetail + N'RESOURCE_SEMAPHORE wait=' + CAST(@SemWaitMsPerHour AS NVARCHAR(20))
                                + N' ms/hour exceeds threshold ' + CAST(@MaxSemWaitMsPerHour AS NVARCHAR(20)) + N' ms/hour; ';
        END;

        IF @PressureDetected = 0
            SET @PressureDetail = N'no grant timeouts, no forced grants, no queued grants, RESOURCE_SEMAPHORE wait '
                                + CAST(@SemWaitMsPerHour AS NVARCHAR(20)) + N' ms/hour within threshold '
                                + CAST(@MaxSemWaitMsPerHour AS NVARCHAR(20)) + N' ms/hour';

        /* -- 7. Describe monitoring coverage --------------------------------------- */
        IF @XeChecked = 0
            SET @MonitorDetail = N'Extended Events metadata could not be read (insufficient permission), so spill monitoring coverage is undetermined';
        ELSE IF @ActiveMonitors > 0
            SET @MonitorDetail = CAST(@ActiveMonitors AS NVARCHAR(10))
                               + N' running Extended Events session(s) capture memory grant / spill events: '
                               + ISNULL(@MonitorNames, N'(unnamed)');
        ELSE IF @DefinedMonitors > 0
            SET @MonitorDetail = CAST(@DefinedMonitors AS NVARCHAR(10))
                               + N' Extended Events session(s) capturing memory grant / spill events exist but are NOT running';
        ELSE
            SET @MonitorDetail = N'no Extended Events session captures sort_warning / hash_warning / hash_spill_details / exchange_spill or memory grant events';

        /* -- 8. Score -------------------------------------------------------------- */
        IF @ActiveMonitors > 0 AND @PressureDetected = 0
            SET @Score = 3;
        ELSE IF (@ActiveMonitors > 0 AND @PressureDetected = 1)
             OR (@ActiveMonitors = 0 AND @PressureDetected = 0)
            SET @Score = 2;
        ELSE
            SET @Score = 1;

        SET @Finding = N'Monitoring coverage: ' + @MonitorDetail + N'. '
                     + N'Memory grant pressure: ' + @PressureDetail + N'. '
                     + N'Metrics since instance start ('
                     + ISNULL(CAST(@UptimeHours AS NVARCHAR(20)), N'unknown') + N' h): RESOURCE_SEMAPHORE waits='
                     + CAST(@SemWaitTasks AS NVARCHAR(20)) + N' tasks / ' + CAST(@SemWaitMs AS NVARCHAR(20)) + N' ms ('
                     + CAST(@SemWaitMsPerHour AS NVARCHAR(20)) + N' ms/hour), RESOURCE_SEMAPHORE_QUERY_COMPILE waits='
                     + CAST(@CompileWaitMs AS NVARCHAR(20)) + N' ms, timeout_error_count='
                     + CAST(@TimeoutErrors AS NVARCHAR(20)) + N', forced_grant_count='
                     + CAST(@ForcedGrants AS NVARCHAR(20)) + N', semaphore waiter_count='
                     + CAST(@CurrentWaiters AS NVARCHAR(20)) + N'; grants in flight now=' + CAST(@ActiveGrants AS NVARCHAR(20))
                     + N' (queued=' + CAST(@QueuedGrants AS NVARCHAR(20)) + N'). '
                     + N'Grant timeouts, forced grants and RESOURCE_SEMAPHORE waits indicate under-sized memory grants, '
                     + N'which is what drives sort/hash spills to tempdb.';

    END TRY
    BEGIN CATCH
        SET @Score   = 0;
        SET @Finding = N'Memory grant monitoring could not be evaluated automatically. Error '
                     + CAST(ERROR_NUMBER() AS NVARCHAR(20)) + N': ' + ERROR_MESSAGE()
                     + N' VIEW SERVER STATE (VIEW DATABASE STATE on Azure SQL Database) is required to read '
                     + N'sys.dm_os_wait_stats, sys.dm_exec_query_resource_semaphores and sys.dm_exec_query_memory_grants.';
    END CATCH;
END;

IF OBJECT_ID(N'tempdb..#MemoryGrantMonitors') IS NOT NULL
    DROP TABLE #MemoryGrantMonitors;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result    AS Result,
    @Score     AS Score,
    @ScopeName AS DatabaseQueried,
    @Finding   AS Finding;