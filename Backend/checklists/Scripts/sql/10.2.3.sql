SET NOCOUNT ON;

DECLARE @Result NVARCHAR(20);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(200);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @WaitSignal INT = 0;
DECLARE @MissingSignal INT = 0;
DECLARE @UsageSignal INT = 0;
DECLARE @SignalCount INT = 0;

DECLARE @WaitRows INT = 0;
DECLARE @MeaningfulWaits INT = 0;
DECLARE @TopWait NVARCHAR(128) = NULL;
DECLARE @TopWaitMs BIGINT = 0;

DECLARE @MissingIdxGroups INT = 0;
DECLARE @UsageStatRows INT = 0;
DECLARE @UnusedIndexRows INT = 0;
DECLARE @DbTouched INT = 0;
DECLARE @IsAzure BIT = 0;

SET @DatabaseQueried = N'server';

IF SERVERPROPERTY('EngineEdition') = 5
    SET @IsAzure = 1;

/* Category 1: wait stats DMV */
BEGIN TRY
    SELECT
        @WaitRows = COUNT(*),
        @MeaningfulWaits = SUM(CASE
            WHEN wait_type NOT IN (
                N'BROKER_EVENTHANDLER', N'BROKER_RECEIVE_WAITFOR', N'BROKER_TASK_STOP',
                N'BROKER_TO_FLUSH', N'BROKER_TRANSMITTER', N'CHECKPOINT_QUEUE',
                N'CHKPT', N'CLR_AUTO_EVENT', N'CLR_MANUAL_EVENT', N'CLR_SEMAPHORE',
                N'DBMIRROR_DBM_EVENT', N'DBMIRROR_EVENTS_QUEUE', N'DBMIRROR_WORKER_QUEUE',
                N'DBMIRRORING_CMD', N'DIRTY_PAGE_POLL', N'DISPATCHER_QUEUE_SEMAPHORE',
                N'EXECSYNC', N'FSAGENT', N'FT_IFTS_SCHEDULER_IDLE_WAIT', N'FT_IFTSHC_MUTEX',
                N'HADR_CLUSAPI_CALL', N'HADR_FILESTREAM_IOMGR_IOCOMPLETION', N'HADR_LOGCAPTURE_WAIT',
                N'HADR_NOTIFICATION_DEQUEUE', N'HADR_TIMER_TASK', N'HADR_WORK_QUEUE',
                N'KSOURCE_WAKEUP', N'LAZYWRITER_SLEEP', N'LOGMGR_QUEUE', N'MEMORY_ALLOCATION_EXT',
                N'ONDEMAND_TASK_QUEUE', N'PARALLEL_REDO_DRAIN_WORKER', N'PARALLEL_REDO_LOG_CACHE',
                N'PARALLEL_REDO_TRAN_LIST', N'PARALLEL_REDO_WORKER_SYNC', N'PARALLEL_REDO_WORKER_WAIT_WORK',
                N'PREEMPTIVE_OS_FLUSHFILEBUFFERS', N'PREEMPTIVE_XE_GETTARGETSTATE',
                N'PWAIT_ALL_COMPONENTS_INITIALIZED', N'PWAIT_DIRECTLOGCONSUMER_GETNEXT',
                N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', N'QDS_ASYNC_QUEUE',
                N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP', N'QDS_SHUTDOWN_QUEUE',
                N'REDO_THREAD_PENDING_WORK', N'REQUEST_FOR_DEADLOCK_SEARCH', N'RESOURCE_QUEUE',
                N'SERVER_IDLE_CHECK', N'SLEEP_BPOOL_FLUSH', N'SLEEP_DBSTARTUP', N'SLEEP_DCOMSTARTUP',
                N'SLEEP_MASTERDBREADY', N'SLEEP_MASTERMDREADY', N'SLEEP_MASTERUPGRADED',
                N'SLEEP_MSDBSTARTUP', N'SLEEP_SYSTEMTASK', N'SLEEP_TASK', N'SLEEP_TEMPDBSTARTUP',
                N'SNI_HTTP_ACCEPT', N'SP_SERVER_DIAGNOSTICS_SLEEP', N'SQLTRACE_BUFFER_FLUSH',
                N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', N'SQLTRACE_WAIT_ENTRIES', N'WAIT_FOR_RESULTS',
                N'WAITFOR', N'WAITFOR_TASKSHUTDOWN', N'WAIT_XTP_HOST_WAIT',
                N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG', N'WAIT_XTP_CKPT_CLOSE', N'XE_DISPATCHER_JOIN',
                N'XE_DISPATCHER_WAIT', N'XE_TIMER_EVENT'
            ) AND waiting_tasks_count > 0 THEN 1 ELSE 0 END)
    FROM sys.dm_os_wait_stats;

    SELECT TOP (1)
        @TopWait = wait_type,
        @TopWaitMs = wait_time_ms
    FROM sys.dm_os_wait_stats
    WHERE wait_type NOT IN (
        N'BROKER_EVENTHANDLER', N'BROKER_RECEIVE_WAITFOR', N'BROKER_TASK_STOP',
        N'BROKER_TO_FLUSH', N'BROKER_TRANSMITTER', N'CHECKPOINT_QUEUE',
        N'CHKPT', N'CLR_AUTO_EVENT', N'CLR_MANUAL_EVENT', N'CLR_SEMAPHORE',
        N'DBMIRROR_DBM_EVENT', N'DBMIRROR_EVENTS_QUEUE', N'DBMIRROR_WORKER_QUEUE',
        N'DBMIRRORING_CMD', N'DIRTY_PAGE_POLL', N'DISPATCHER_QUEUE_SEMAPHORE',
        N'EXECSYNC', N'FSAGENT', N'FT_IFTS_SCHEDULER_IDLE_WAIT', N'FT_IFTSHC_MUTEX',
        N'HADR_CLUSAPI_CALL', N'HADR_FILESTREAM_IOMGR_IOCOMPLETION', N'HADR_LOGCAPTURE_WAIT',
        N'HADR_NOTIFICATION_DEQUEUE', N'HADR_TIMER_TASK', N'HADR_WORK_QUEUE',
        N'KSOURCE_WAKEUP', N'LAZYWRITER_SLEEP', N'LOGMGR_QUEUE', N'MEMORY_ALLOCATION_EXT',
        N'ONDEMAND_TASK_QUEUE', N'PARALLEL_REDO_DRAIN_WORKER', N'PARALLEL_REDO_LOG_CACHE',
        N'PARALLEL_REDO_TRAN_LIST', N'PARALLEL_REDO_WORKER_SYNC', N'PARALLEL_REDO_WORKER_WAIT_WORK',
        N'PREEMPTIVE_OS_FLUSHFILEBUFFERS', N'PREEMPTIVE_XE_GETTARGETSTATE',
        N'PWAIT_ALL_COMPONENTS_INITIALIZED', N'PWAIT_DIRECTLOGCONSUMER_GETNEXT',
        N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', N'QDS_ASYNC_QUEUE',
        N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP', N'QDS_SHUTDOWN_QUEUE',
        N'REDO_THREAD_PENDING_WORK', N'REQUEST_FOR_DEADLOCK_SEARCH', N'RESOURCE_QUEUE',
        N'SERVER_IDLE_CHECK', N'SLEEP_BPOOL_FLUSH', N'SLEEP_DBSTARTUP', N'SLEEP_DCOMSTARTUP',
        N'SLEEP_MASTERDBREADY', N'SLEEP_MASTERMDREADY', N'SLEEP_MASTERUPGRADED',
        N'SLEEP_MSDBSTARTUP', N'SLEEP_SYSTEMTASK', N'SLEEP_TASK', N'SLEEP_TEMPDBSTARTUP',
        N'SNI_HTTP_ACCEPT', N'SP_SERVER_DIAGNOSTICS_SLEEP', N'SQLTRACE_BUFFER_FLUSH',
        N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', N'SQLTRACE_WAIT_ENTRIES', N'WAIT_FOR_RESULTS',
        N'WAITFOR', N'WAITFOR_TASKSHUTDOWN', N'WAIT_XTP_HOST_WAIT',
        N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG', N'WAIT_XTP_CKPT_CLOSE', N'XE_DISPATCHER_JOIN',
        N'XE_DISPATCHER_WAIT', N'XE_TIMER_EVENT'
    )
    ORDER BY wait_time_ms DESC;

    IF @WaitRows > 0
        SET @WaitSignal = 1;
END TRY
BEGIN CATCH
    SET @WaitSignal = 0;
END CATCH;

/* Categories 2-3: missing-index and index-usage DMVs (database-scoped) */
IF OBJECT_ID('tempdb..#IdxDmv') IS NOT NULL DROP TABLE #IdxDmv;
CREATE TABLE #IdxDmv
(
    DbName SYSNAME NOT NULL,
    MissingGroups INT NOT NULL,
    UsageRows INT NOT NULL,
    UnusedRows INT NOT NULL
);

IF @IsAzure = 1
BEGIN
    BEGIN TRY
        INSERT INTO #IdxDmv (DbName, MissingGroups, UsageRows, UnusedRows)
        SELECT
            DB_NAME(),
            (SELECT COUNT(*) FROM sys.dm_db_missing_index_groups),
            (SELECT COUNT(*) FROM sys.dm_db_index_usage_stats WHERE database_id = DB_ID()),
            (
                SELECT COUNT(*)
                FROM sys.indexes AS i
                INNER JOIN sys.tables AS t ON t.object_id = i.object_id
                LEFT JOIN sys.dm_db_index_usage_stats AS u
                    ON u.object_id = i.object_id
                   AND u.index_id = i.index_id
                   AND u.database_id = DB_ID()
                WHERE i.index_id > 0
                  AND t.is_ms_shipped = 0
                  AND ISNULL(u.user_seeks, 0) = 0
                  AND ISNULL(u.user_scans, 0) = 0
                  AND ISNULL(u.user_lookups, 0) = 0
            );
    END TRY
    BEGIN CATCH
        /* leave empty on permission/access failure */
    END CATCH;
END
ELSE
BEGIN
    DECLARE @DbName SYSNAME;
    DECLARE @Sql NVARCHAR(MAX);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name
        FROM sys.databases
        WHERE database_id > 4
          AND state_desc = N'ONLINE'
          AND HAS_DBACCESS(name) = 1
          AND is_read_only = 0
          AND is_distributor = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Sql = N'
        BEGIN TRY
            INSERT INTO #IdxDmv (DbName, MissingGroups, UsageRows, UnusedRows)
            SELECT
                @DbNameIn,
                (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.dm_db_missing_index_groups),
                (SELECT COUNT(*) FROM sys.dm_db_index_usage_stats WHERE database_id = DB_ID(@DbNameIn)),
                (
                    SELECT COUNT(*)
                    FROM ' + QUOTENAME(@DbName) + N'.sys.indexes AS i
                    INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.tables AS t ON t.object_id = i.object_id
                    LEFT JOIN sys.dm_db_index_usage_stats AS u
                        ON u.object_id = i.object_id
                       AND u.index_id = i.index_id
                       AND u.database_id = DB_ID(@DbNameIn)
                    WHERE i.index_id > 0
                      AND t.is_ms_shipped = 0
                      AND ISNULL(u.user_seeks, 0) = 0
                      AND ISNULL(u.user_scans, 0) = 0
                      AND ISNULL(u.user_lookups, 0) = 0
                );
        END TRY
        BEGIN CATCH
        END CATCH;';

        BEGIN TRY
            EXEC sys.sp_executesql @Sql, N'@DbNameIn SYSNAME', @DbNameIn = @DbName;
        END TRY
        BEGIN CATCH
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SELECT
    @DbTouched = COUNT(*),
    @MissingIdxGroups = ISNULL(SUM(MissingGroups), 0),
    @UsageStatRows = ISNULL(SUM(UsageRows), 0),
    @UnusedIndexRows = ISNULL(SUM(UnusedRows), 0)
FROM #IdxDmv;

IF @DbTouched > 0
    SET @MissingSignal = 1;

IF @DbTouched > 0
    SET @UsageSignal = 1;

SET @SignalCount = @WaitSignal + @MissingSignal + @UsageSignal;

IF @SignalCount >= 3
    SET @Score = 3;
ELSE IF @SignalCount = 2
    SET @Score = 2;
ELSE IF @SignalCount = 1
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding = N'Wait DMV usable=' + CASE WHEN @WaitSignal = 1 THEN N'yes' ELSE N'no' END
    + N' (rows=' + CAST(@WaitRows AS NVARCHAR(20))
    + N', meaningful_wait_types=' + CAST(ISNULL(@MeaningfulWaits, 0) AS NVARCHAR(20))
    + CASE WHEN @TopWait IS NOT NULL
           THEN N', top_wait=' + @TopWait + N'/' + CAST(@TopWaitMs AS NVARCHAR(30)) + N'ms'
           ELSE N'' END
    + N'). Missing-index DMV usable=' + CASE WHEN @MissingSignal = 1 THEN N'yes' ELSE N'no' END
    + N' (dbs=' + CAST(@DbTouched AS NVARCHAR(20))
    + N', missing_index_groups=' + CAST(@MissingIdxGroups AS NVARCHAR(20))
    + N'). Index-usage DMV usable=' + CASE WHEN @UsageSignal = 1 THEN N'yes' ELSE N'no' END
    + N' (usage_rows=' + CAST(@UsageStatRows AS NVARCHAR(20))
    + N', potentially_unused_indexes=' + CAST(@UnusedIndexRows AS NVARCHAR(20))
    + N'). Categories available for performance analysis: '
    + CAST(@SignalCount AS NVARCHAR(10)) + N'/3.';

IF OBJECT_ID('tempdb..#IdxDmv') IS NOT NULL DROP TABLE #IdxDmv;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;