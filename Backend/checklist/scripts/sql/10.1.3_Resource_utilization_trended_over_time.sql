USE master;
SET NOCOUNT ON;
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @JobCount INT = 0;
DECLARE @XeCount INT = 0;

-- Check for SQL Agent jobs related to resource/performance collection
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs)
BEGIN
    SELECT @JobCount = COUNT(*) 
    FROM msdb.dbo.sysjobs
    WHERE name LIKE '%resource%' OR name LIKE '%performance%' OR name LIKE '%counter%'
       OR name LIKE '%wait%' OR name LIKE '%dmv%' OR name LIKE '%collection%'
       OR name LIKE '%health%' OR name LIKE '%monitor%';
END

-- Check for Extended Event sessions capturing resource metrics
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions)
BEGIN
    SELECT @XeCount = COUNT(DISTINCT s.name)
    FROM sys.dm_xe_sessions s
    JOIN sys.dm_xe_session_events se ON s.address = se.event_session_address
    JOIN sys.dm_xe_objects eo ON se.event_name = eo.name AND eo.object_type = N'event'
    WHERE eo.name IN (
        'cpu_ring_buffer_recorded', 'memory_broker_ring_buffer_recorded',
        'wait_info', 'wait_stats', 'page_life_expectancy',
        'batch_completed', 'sql_statement_completed', 'sp_server_diagnostics_component_result'
    );
END

-- Determine score based on evidence
IF @JobCount > 0 AND @XeCount > 0
    SET @Score = 2; -- Automated mechanisms detected. Score 3 requires manual verification of historical storage retention per checklist.
ELSE IF @JobCount > 0 OR @XeCount > 0
    SET @Score = 2;
ELSE
BEGIN
    -- Check for ad-hoc procedures/functions that query DMVs (proxy for manual/ad-hoc)
    -- Uses server-wide catalog views to cover all databases without iteration
    IF EXISTS (
        SELECT 1 FROM sys.all_objects p
        CROSS APPLY sys.all_sql_modules m ON p.object_id = m.object_id
        WHERE p.is_ms_shipped = 0
        AND (m.definition LIKE '%sys.dm_os_performance_counters%'
          OR m.definition LIKE '%sys.dm_os_wait_stats%'
          OR m.definition LIKE '%sys.dm_os_sys_memory%')
    )
        SET @Score = 1;
    ELSE
        SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;