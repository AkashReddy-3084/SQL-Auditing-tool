-- Checklist: Memory grants monitored (no excessive spills to tempdb)
-- Scope: SERVER
-- Scoring: 3 = a running Extended Events session captures spill / memory-grant events and no memory-grant pressure is observed; 2 = monitoring is running but pressure is observed, or no pressure is observed without dedicated monitoring; 1 = no monitoring and memory-grant pressure is observed; 0 = the memory-grant DMVs could not be read

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Memory grant evidence could not be read';
DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Timeouts BIGINT = 0;
DECLARE @ForcedGrants BIGINT = 0;
DECLARE @QueuedGrants INT = 0;
DECLARE @ActiveGrants INT = 0;
DECLARE @SemWaitMs BIGINT = 0;
DECLARE @UptimeHours DECIMAL(18, 2) = 0;
DECLARE @WaitPerHour BIGINT = 0;
DECLARE @Monitors INT = 0;
DECLARE @MonitorNames NVARCHAR(MAX) = '';
DECLARE @Pressure BIT = 0;
DECLARE @Read BIT = 0;

DECLARE @Xe TABLE (SessionName NVARCHAR(128) NOT NULL);

BEGIN TRY
    SELECT @UptimeHours = ISNULL(MAX(DATEDIFF(MINUTE, sqlserver_start_time, SYSDATETIME())) / 60.0, 0)
    FROM sys.dm_os_sys_info;

    SELECT @SemWaitMs = ISNULL(SUM(CONVERT(BIGINT, wait_time_ms)), 0)
    FROM sys.dm_os_wait_stats
    WHERE wait_type = 'RESOURCE_SEMAPHORE';

    SELECT @Timeouts = ISNULL(SUM(CONVERT(BIGINT, timeout_error_count)), 0),
           @ForcedGrants = ISNULL(SUM(CONVERT(BIGINT, forced_grant_count)), 0)
    FROM sys.dm_exec_query_resource_semaphores;

    SELECT @ActiveGrants = COUNT(*),
           @QueuedGrants = ISNULL(SUM(CASE WHEN grant_time IS NULL THEN 1 ELSE 0 END), 0)
    FROM sys.dm_exec_query_memory_grants;

    SET @Read = 1;
END TRY
BEGIN CATCH
    SET @Read = 0;
END CATCH;

-- Spill / memory-grant event sessions live in different catalog views per engine edition.
BEGIN TRY
    SET @Sql = CASE WHEN @Edition = 5 THEN
        N'SELECT DISTINCT s.name
          FROM sys.dm_xe_database_sessions AS s
          JOIN sys.dm_xe_database_session_events AS e ON e.event_session_address = s.address
          WHERE e.name IN (''sort_warning'', ''hash_warning'', ''hash_spill_details'',
                           ''exchange_spill'', ''query_memory_grant_usage'', ''query_memory_grant_blocking'');'
      ELSE
        N'SELECT DISTINCT s.name
          FROM sys.dm_xe_sessions AS s
          JOIN sys.dm_xe_session_events AS e ON e.event_session_address = s.address
          WHERE e.name IN (''sort_warning'', ''hash_warning'', ''hash_spill_details'',
                           ''exchange_spill'', ''query_memory_grant_usage'', ''query_memory_grant_blocking'');'
      END;

    INSERT INTO @Xe (SessionName)
    EXEC sys.sp_executesql @Sql;
END TRY
BEGIN CATCH
    SET @MonitorNames = '';
END CATCH;

SELECT @Monitors = COUNT(*) FROM @Xe;

SELECT @MonitorNames = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), SessionName), ', '), 300), 'none')
FROM @Xe;

SET @WaitPerHour = CASE WHEN @UptimeHours > 0 THEN CONVERT(BIGINT, @SemWaitMs / @UptimeHours) ELSE @SemWaitMs END;

SET @Pressure = CASE
    WHEN @Timeouts > 0 OR @ForcedGrants > 0 OR @QueuedGrants > 0 OR @WaitPerHour > 60000 THEN 1
    ELSE 0
END;

SET @Score = CASE
    WHEN @Read = 0 THEN 0
    WHEN @Monitors > 0 AND @Pressure = 0 THEN 3
    WHEN @Monitors > 0 OR @Pressure = 0 THEN 2
    ELSE 1
END;

SET @Finding = CASE
    WHEN @Read = 0
        THEN 'sys.dm_exec_query_memory_grants and sys.dm_exec_query_resource_semaphores could not be read; memory grant pressure is unknown'
    ELSE CONCAT(
        'running Extended Events sessions capturing spill / memory-grant events = ', @Monitors, ' (', @MonitorNames, ')',
        '; memory grant timeout errors = ', @Timeouts,
        '; forced (reduced) grants = ', @ForcedGrants,
        '; grants currently queued for memory = ', @QueuedGrants, ' of ', @ActiveGrants, ' in flight',
        '; RESOURCE_SEMAPHORE wait = ', @WaitPerHour, ' ms per hour of uptime (', @UptimeHours, ' h)')
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
