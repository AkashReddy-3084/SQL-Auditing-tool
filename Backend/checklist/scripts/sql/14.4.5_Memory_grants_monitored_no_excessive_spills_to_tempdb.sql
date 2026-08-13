-- Checklist: Memory grants monitored (no excessive spills to tempdb)
-- Scope: SERVER
-- Scoring: 0=No monitoring & excessive spills; 1=No monitoring & low spills; 2=Monitoring configured & low spills; 3=Comprehensive monitoring & zero spills
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @ActiveSpills INT = 0;
DECLARE @XeConfigured BIT = 0;
DECLARE @SpillRate FLOAT = 0;

-- Check for active queries experiencing memory spills
-- A spill occurs when granted memory is less than required memory
SELECT @ActiveSpills = COUNT(*) 
FROM sys.dm_exec_query_memory_grants 
WHERE granted_memory_kb < required_memory_kb;

-- Check for Extended Events monitoring spills (On-prem/MI only)
-- Verifies both configuration and active running state
IF OBJECT_ID('sys.server_event_sessions') IS NOT NULL
BEGIN
    SELECT @XeConfigured = CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END
    FROM sys.server_event_sessions ses
    JOIN sys.server_event_session_events see ON ses.event_session_id = see.event_session_id
    JOIN sys.server_events se ON see.event_id = se.event_id
    WHERE se.name = 'spilled_memory_grant' AND ses.is_started = 1;
END

-- Check historical spill rate from performance counters
SELECT @SpillRate = ISNULL(MAX(cntr_value), 0) 
FROM sys.dm_os_performance_counters 
WHERE counter_name = 'Spills to tempdb/sec';

-- Determine score based on monitoring presence and spill severity
-- Threshold: < 1.0 spills/sec = low, >= 1.0 = excessive
IF @XeConfigured = 1 AND @ActiveSpills = 0 AND @SpillRate = 0
    SET @Score = 3;
ELSE IF @XeConfigured = 1 AND @ActiveSpills = 0 AND @SpillRate < 1.0
    SET @Score = 2;
ELSE IF @XeConfigured = 0 AND @ActiveSpills = 0 AND @SpillRate < 1.0
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;