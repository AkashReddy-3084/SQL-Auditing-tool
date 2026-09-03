SET NOCOUNT ON;

DECLARE @Result          VARCHAR(10)  = 'Fail';
DECLARE @Score           INT          = 0;
DECLARE @DatabaseQueried NVARCHAR(200) = N'N/A';
DECLARE @Finding         NVARCHAR(MAX) = N'';

DECLARE @IsAzure         BIT = 0;
DECLARE @CatCpu          BIT = 0;
DECLARE @CatMemory       BIT = 0;
DECLARE @CatIo           BIT = 0;
DECLARE @CatResource     BIT = 0;
DECLARE @CatWaits        BIT = 0;
DECLARE @CategoryCount   INT = 0;

DECLARE @CpuDetail       NVARCHAR(200) = N'CPU: not available';
DECLARE @MemDetail       NVARCHAR(200) = N'Memory: not available';
DECLARE @IoDetail        NVARCHAR(200) = N'IO: not available';
DECLARE @ResDetail       NVARCHAR(200) = N'Resource/DTU-vCore: not available';
DECLARE @WaitDetail      NVARCHAR(200) = N'Waits: not available';

DECLARE @Runnable        INT = 0;
DECLARE @SchedulerCnt    INT = 0;
DECLARE @PhysicalMemKb   BIGINT = 0;
DECLARE @IoReads         BIGINT = 0;
DECLARE @IoWrites        BIGINT = 0;
DECLARE @WaitTypes       INT = 0;
DECLARE @WaitMs          BIGINT = 0;
DECLARE @AvgCpuPercent   DECIMAL(5, 2) = NULL;
DECLARE @AvgDtuPercent   DECIMAL(5, 2) = NULL;
DECLARE @ResourceSamples INT = 0;
DECLARE @BatchReq        BIGINT = NULL;
DECLARE @Ple             BIGINT = NULL;
DECLARE @CpuCount        INT = NULL;

BEGIN TRY
    IF SERVERPROPERTY('EngineEdition') = 5
        SET @IsAzure = 1;

    /* CPU — schedulers show runnable/active workload signal */
    SELECT
        @Runnable     = ISNULL(SUM(CASE WHEN runnable_tasks_count > 0 THEN runnable_tasks_count ELSE 0 END), 0),
        @SchedulerCnt = ISNULL(SUM(CASE WHEN status = N'VISIBLE ONLINE' THEN 1 ELSE 0 END), 0)
    FROM sys.dm_os_schedulers
    WHERE scheduler_id < 255;

    IF @SchedulerCnt > 0
    BEGIN
        SET @CatCpu = 1;
        SET @CpuDetail = N'CPU: ' + CAST(@SchedulerCnt AS NVARCHAR(20))
            + N' online scheduler(s); runnable_tasks=' + CAST(@Runnable AS NVARCHAR(20));
    END

    /* Memory — process memory DMV */
    IF OBJECT_ID(N'sys.dm_os_process_memory') IS NOT NULL
    BEGIN
        SELECT @PhysicalMemKb = ISNULL(physical_memory_in_use_kb, 0)
        FROM sys.dm_os_process_memory;

        IF @PhysicalMemKb > 0
        BEGIN
            SET @CatMemory = 1;
            SET @MemDetail = N'Memory: physical_memory_in_use_kb='
                + CAST(@PhysicalMemKb AS NVARCHAR(30));
        END
    END

    IF @CatMemory = 0 AND OBJECT_ID(N'sys.dm_os_sys_memory') IS NOT NULL
    BEGIN
        SELECT @PhysicalMemKb = ISNULL(available_physical_memory_kb, 0)
        FROM sys.dm_os_sys_memory;

        IF @PhysicalMemKb >= 0
        BEGIN
            SET @CatMemory = 1;
            SET @MemDetail = N'Memory: available_physical_memory_kb='
                + CAST(@PhysicalMemKb AS NVARCHAR(30));
        END
    END

    /* IO — virtual file stats cumulative reads/writes */
    SELECT
        @IoReads  = ISNULL(SUM(num_of_reads), 0),
        @IoWrites = ISNULL(SUM(num_of_writes), 0)
    FROM sys.dm_io_virtual_file_stats(NULL, NULL);

    IF @IoReads > 0 OR @IoWrites > 0
    BEGIN
        SET @CatIo = 1;
        SET @IoDetail = N'IO: reads=' + CAST(@IoReads AS NVARCHAR(30))
            + N'; writes=' + CAST(@IoWrites AS NVARCHAR(30));
    END

    /* Resource / DTU / vCore */
    IF @IsAzure = 1 AND OBJECT_ID(N'sys.dm_db_resource_stats') IS NOT NULL
    BEGIN
        SELECT
            @ResourceSamples = COUNT(*),
            @AvgCpuPercent   = AVG(CAST(avg_cpu_percent AS DECIMAL(5, 2))),
            @AvgDtuPercent   = AVG(CAST(avg_dtu_percent AS DECIMAL(5, 2)))
        FROM sys.dm_db_resource_stats;

        IF @ResourceSamples > 0
        BEGIN
            SET @CatResource = 1;
            SET @ResDetail = N'Resource/DTU-vCore: samples='
                + CAST(@ResourceSamples AS NVARCHAR(20))
                + N'; avg_cpu_percent='
                + ISNULL(CAST(@AvgCpuPercent AS NVARCHAR(20)), N'n/a')
                + N'; avg_dtu_percent='
                + ISNULL(CAST(@AvgDtuPercent AS NVARCHAR(20)), N'n/a');
            SET @DatabaseQueried = DB_NAME();
        END
    END
    ELSE
    BEGIN
        /* On-prem / non-Azure: performance counters as resource signal */
        IF EXISTS (
            SELECT 1
            FROM sys.dm_os_performance_counters
            WHERE counter_name IN (
                    N'Batch Requests/sec',
                    N'Page life expectancy',
                    N'Processes blocked',
                    N'CPU usage %'
                )
              AND cntr_value IS NOT NULL
        )
        BEGIN
            SELECT TOP 1 @BatchReq = cntr_value
            FROM sys.dm_os_performance_counters
            WHERE counter_name = N'Batch Requests/sec'
              AND instance_name = N'';

            SELECT TOP 1 @Ple = cntr_value
            FROM sys.dm_os_performance_counters
            WHERE counter_name = N'Page life expectancy'
              AND object_name LIKE N'%Buffer Manager%';

            IF @BatchReq IS NOT NULL OR @Ple IS NOT NULL OR @SchedulerCnt > 0
            BEGIN
                SET @CatResource = 1;
                SET @ResDetail = N'Resource/vCore-equiv: BatchRequests/sec='
                    + ISNULL(CAST(@BatchReq AS NVARCHAR(30)), N'n/a')
                    + N'; PLE='
                    + ISNULL(CAST(@Ple AS NVARCHAR(30)), N'n/a');
            END
        END

        /* Fallback: sys.dm_os_sys_info cpu_count as resource inventory signal */
        IF @CatResource = 0 AND OBJECT_ID(N'sys.dm_os_sys_info') IS NOT NULL
        BEGIN
            SELECT @CpuCount = cpu_count FROM sys.dm_os_sys_info;
            IF @CpuCount IS NOT NULL AND @CpuCount > 0
            BEGIN
                SET @CatResource = 1;
                SET @ResDetail = N'Resource/vCore-equiv: cpu_count='
                    + CAST(@CpuCount AS NVARCHAR(20))
                    + N' (sys.dm_os_sys_info)';
            END
        END
    END

    /* Waits — accumulated wait stats excluding benign waits */
    SELECT
        @WaitTypes = COUNT(*),
        @WaitMs    = ISNULL(SUM(wait_time_ms), 0)
    FROM sys.dm_os_wait_stats
    WHERE waiting_tasks_count > 0
      AND wait_time_ms > 0
      AND wait_type NOT IN (
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
            N'PREEMPTIVE_XE_GETTARGETSTATE', N'PWAIT_ALL_COMPONENTS_INITIALIZED',
            N'PWAIT_DIRECTLOGCONSUMER_GETNEXT', N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
            N'QDS_ASYNC_QUEUE', N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
            N'QDS_SHUTDOWN_QUEUE', N'REDO_THREAD_PENDING_WORK', N'REQUEST_FOR_DEADLOCK_SEARCH',
            N'RESOURCE_QUEUE', N'SERVER_IDLE_CHECK', N'SLEEP_BPOOL_FLUSH', N'SLEEP_DBSTARTUP',
            N'SLEEP_DCOMSTARTUP', N'SLEEP_MASTERDBREADY', N'SLEEP_MASTERMDREADY',
            N'SLEEP_MASTERUPGRADED', N'SLEEP_MSDBSTARTUP', N'SLEEP_SYSTEMTASK', N'SLEEP_TASK',
            N'SLEEP_TEMPDBSTARTUP', N'SNI_HTTP_ACCEPT', N'SP_SERVER_DIAGNOSTICS_SLEEP',
            N'SQLTRACE_BUFFER_FLUSH', N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', N'SQLTRACE_WAIT_ENTRIES',
            N'WAIT_FOR_RESULTS', N'WAITFOR', N'WAITFOR_TASKSHUTDOWN', N'WAIT_XTP_RECOVERY',
            N'WAIT_XTP_HOST_WAIT', N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG', N'WAIT_XTP_CKPT_CLOSE',
            N'XE_DISPATCHER_JOIN', N'XE_DISPATCHER_WAIT', N'XE_TIMER_EVENT'
      );

    IF @WaitTypes > 0
    BEGIN
        SET @CatWaits = 1;
        SET @WaitDetail = N'Waits: meaningful_wait_types='
            + CAST(@WaitTypes AS NVARCHAR(20))
            + N'; total_wait_time_ms=' + CAST(@WaitMs AS NVARCHAR(30));
    END

    SET @CategoryCount =
          CAST(@CatCpu AS INT)
        + CAST(@CatMemory AS INT)
        + CAST(@CatIo AS INT)
        + CAST(@CatResource AS INT)
        + CAST(@CatWaits AS INT);

    IF @CategoryCount >= 5
        SET @Score = 3;
    ELSE IF @CategoryCount >= 3
        SET @Score = 2;
    ELSE IF @CategoryCount >= 1
        SET @Score = 1;
    ELSE
        SET @Score = 0;

    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

    SET @Finding = N'Key metric categories tracked: '
        + CAST(@CategoryCount AS NVARCHAR(10))
        + N'/5. '
        + @CpuDetail + N'; '
        + @MemDetail + N'; '
        + @IoDetail + N'; '
        + @ResDetail + N'; '
        + @WaitDetail
        + CASE WHEN @IsAzure = 1 THEN N' [Azure SQL DB]' ELSE N' [Non-Azure]' END
        + N'.';
END TRY
BEGIN CATCH
    SET @Score   = 0;
    SET @Result  = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
    SET @Finding = N'Error checking key metrics tracking: ' + ERROR_MESSAGE();
END CATCH;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;