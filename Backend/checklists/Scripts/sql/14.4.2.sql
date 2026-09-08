SET NOCOUNT ON;

DECLARE @DatabaseQueried nvarchar(128) = N'tempdb';
DECLARE @CpuCount int = 0;
DECLARE @SchedulerCount int = 0;
DECLARE @TempdbDataFiles int = 0;
DECLARE @DistinctSizes int = 0;
DECLARE @MinSizeMb bigint = 0;
DECLARE @MaxSizeMb bigint = 0;
DECLARE @RecommendedFiles int = 0;
DECLARE @PagelatchWaits bigint = 0;
DECLARE @PagelatchWaitMs bigint = 0;
DECLARE @TotalWaits bigint = 0;
DECLARE @ContentionPct decimal(10, 4) = 0;
DECLARE @Result nvarchar(20);
DECLARE @Score int;
DECLARE @Finding nvarchar(max);

BEGIN TRY
    SELECT
        @CpuCount = cpu_count,
        @SchedulerCount = scheduler_count
    FROM sys.dm_os_sys_info;

    SET @RecommendedFiles = CASE
        WHEN ISNULL(@SchedulerCount, @CpuCount) <= 0 THEN 1
        WHEN ISNULL(@SchedulerCount, @CpuCount) >= 8 THEN 8
        ELSE ISNULL(@SchedulerCount, @CpuCount)
    END;

    SELECT
        @TempdbDataFiles = COUNT(*),
        @DistinctSizes = COUNT(DISTINCT size),
        @MinSizeMb = MIN(CONVERT(bigint, size)) * 8 / 1024,
        @MaxSizeMb = MAX(CONVERT(bigint, size)) * 8 / 1024
    FROM sys.master_files
    WHERE database_id = 2
      AND type_desc = N'ROWS';

    SELECT
        @PagelatchWaits = SUM(CAST(waiting_tasks_count AS bigint)),
        @PagelatchWaitMs = SUM(CAST(wait_time_ms AS bigint))
    FROM sys.dm_os_wait_stats
    WHERE wait_type IN (
        N'PAGELATCH_UP',
        N'PAGELATCH_SH',
        N'PAGELATCH_EX',
        N'PAGELATCH_KP',
        N'PAGELATCH_DT'
    );

    SELECT @TotalWaits = SUM(CAST(waiting_tasks_count AS bigint))
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
    );

    IF ISNULL(@TotalWaits, 0) > 0
        SET @ContentionPct = CONVERT(decimal(10, 4), (100.0 * ISNULL(@PagelatchWaits, 0)) / @TotalWaits);

    IF @TempdbDataFiles = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = N'Unable to read tempdb data files from sys.master_files.';
    END
    ELSE IF @TempdbDataFiles = 1
    BEGIN
        SET @Score = 1;
        SET @Finding = N'tempdb has only 1 data file; recommended near ' + CAST(@RecommendedFiles AS nvarchar(11))
            + N' (scheduler_count=' + CAST(ISNULL(@SchedulerCount, 0) AS nvarchar(11))
            + N'). PAGELATCH waits=' + CAST(ISNULL(@PagelatchWaits, 0) AS nvarchar(20))
            + N' (' + CAST(@ContentionPct AS nvarchar(20)) + N'% of non-idle waits). Single-file layout increases allocation-page contention risk.';
    END
    ELSE IF @TempdbDataFiles < @RecommendedFiles
         OR @DistinctSizes > 1
         OR @ContentionPct >= 5.0
    BEGIN
        SET @Score = 2;
        SET @Finding = N'tempdb data files=' + CAST(@TempdbDataFiles AS nvarchar(11))
            + N' (recommended ~' + CAST(@RecommendedFiles AS nvarchar(11))
            + N'), size range MB=' + CAST(@MinSizeMb AS nvarchar(20)) + N'-' + CAST(@MaxSizeMb AS nvarchar(20))
            + N' (distinct sizes=' + CAST(@DistinctSizes AS nvarchar(11))
            + N'), PAGELATCH waits=' + CAST(ISNULL(@PagelatchWaits, 0) AS nvarchar(20))
            + N' (' + CAST(@ContentionPct AS nvarchar(20))
            + N'% of non-idle waits). Partial mitigation present; equalize file sizes and/or increase file count, and continue monitoring allocation waits.';
    END
    ELSE
    BEGIN
        SET @Score = 3;
        SET @Finding = N'tempdb data files=' + CAST(@TempdbDataFiles AS nvarchar(11))
            + N' meeting ~' + CAST(@RecommendedFiles AS nvarchar(11))
            + N' scheduler guidance; all data files equal size (' + CAST(@MinSizeMb AS nvarchar(20))
            + N' MB). PAGELATCH waits=' + CAST(ISNULL(@PagelatchWaits, 0) AS nvarchar(20))
            + N' (' + CAST(@ContentionPct AS nvarchar(20))
            + N'% of non-idle waits). Technical mitigation controls look healthy; keep monitoring tempdb contention.';
    END
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Error assessing tempdb contention controls: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;