-- Checklist: Blocking monitored and root causes addressed
-- Scope: SERVER
-- Scoring: 0=No monitoring configured; 1=Monitoring exists (Agent job or XE); 2=Monitoring + tuning/maintenance evidence; 3=Monitoring + tuning + low/zero current blocking (proxy for addressed root causes)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @MonitorExists BIT = 0;
DECLARE @TuningExists BIT = 0;
DECLARE @BlockingCount INT = 0;

-- Check for monitoring jobs (On-prem/MI)
IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name LIKE '%block%' OR name LIKE '%deadlock%' OR name LIKE '%wait%')
        SET @MonitorExists = 1;
END

-- Check for Extended Events sessions capturing blocking/deadlocks
IF EXISTS (
    SELECT 1 FROM sys.dm_xe_sessions
    WHERE name LIKE '%block%' OR name LIKE '%deadlock%' OR name LIKE '%wait%'
)
    SET @MonitorExists = 1;

-- Check for tuning/maintenance evidence
IF EXISTS (
    SELECT 1 FROM sys.configurations
    WHERE (name = 'cost threshold for parallelism' AND CAST(value_in_use AS INT) > 5)
       OR (name = 'max degree of parallelism' AND CAST(value_in_use AS INT) > 0)
)
    SET @TuningExists = 1;

IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    IF EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobs
        WHERE name LIKE '%index%' OR name LIKE '%maintenance%' OR name LIKE '%rebuild%'
    )
        SET @TuningExists = 1;
END

-- Check current blocking
SELECT @BlockingCount = COUNT(*) FROM sys.dm_os_waiting_tasks
WHERE wait_type LIKE 'LCK%';

-- Calculate score based on strict hierarchical scoring logic
IF @MonitorExists = 0
    SET @Score = 0;
ELSE IF @TuningExists = 0
    SET @Score = 1;
ELSE IF @BlockingCount > 5
    SET @Score = 2;
ELSE
    SET @Score = 3;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

-- NOTE: This script provides automated evidence. Full compliance requires human review.
SELECT @Result AS Result, @Score AS Score;