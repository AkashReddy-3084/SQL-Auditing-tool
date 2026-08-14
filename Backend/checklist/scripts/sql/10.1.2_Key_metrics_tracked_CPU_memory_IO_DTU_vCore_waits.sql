-- Checklist: Key metrics tracked (CPU, memory, IO, DTU/vCore, waits)
-- Scope: SERVER
-- Scoring: 0=No metrics tracked, 1=1 metric tracked, 2=2-3 metrics tracked, 3=4-5 metrics tracked
-- NOTE: This script checks for configured monitoring infrastructure (Extended Events or SQL Agent Jobs).
-- Full compliance may require human review to validate naming conventions and collection intervals.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @MetricsTracked INT = 0;
DECLARE @MsdbAvailable BIT = CASE WHEN OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL THEN 1 ELSE 0 END;

-- 1. CPU tracking (checks for XE sessions or Agent Jobs with relevant names)
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name LIKE '%cpu%' OR name LIKE '%processor%')
   OR (@MsdbAvailable = 1 AND EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name LIKE '%cpu%' OR name LIKE '%processor%'))
   SET @MetricsTracked += 1;

-- 2. Memory tracking
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name LIKE '%memory%' OR name LIKE '%mem%')
   OR (@MsdbAvailable = 1 AND EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name LIKE '%memory%' OR name LIKE '%mem%'))
   SET @MetricsTracked += 1;

-- 3. IO tracking
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name LIKE '%io%' OR name LIKE '%disk%')
   OR (@MsdbAvailable = 1 AND EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name LIKE '%io%' OR name LIKE '%disk%'))
   SET @MetricsTracked += 1;

-- 4. DTU/vCore tracking
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name LIKE '%dtu%' OR name LIKE '%vcore%')
   OR (@MsdbAvailable = 1 AND EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name LIKE '%dtu%' OR name LIKE '%vcore%'))
   SET @MetricsTracked += 1;

-- 5. Waits tracking
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name LIKE '%wait%' OR name LIKE '%blocking%')
   OR (@MsdbAvailable = 1 AND EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name LIKE '%wait%' OR name LIKE '%blocking%'))
   SET @MetricsTracked += 1;

-- Cap at 5 core metrics
SET @MetricsTracked = CASE WHEN @MetricsTracked > 5 THEN 5 ELSE @MetricsTracked END;

-- Apply scoring logic per checklist specification
SET @Score = CASE
    WHEN @MetricsTracked = 0 THEN 0
    WHEN @MetricsTracked = 1 THEN 1
    WHEN @MetricsTracked BETWEEN 2 AND 3 THEN 2
    WHEN @MetricsTracked BETWEEN 4 AND 5 THEN 3
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;