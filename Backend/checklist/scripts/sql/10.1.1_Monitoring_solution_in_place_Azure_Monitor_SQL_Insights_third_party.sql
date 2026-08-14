-- Checklist: Monitoring solution in place (Azure Monitor / SQL Insights / third-party)
-- Scope: SERVER
-- Scoring: 0=No evidence, 1=Only default system_health XE, 2=Custom monitoring XE/jobs/telemetry found (proxy evidence capped at 2)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @CustomXECount INT = 0;
DECLARE @JobCount INT = 0;
DECLARE @ExtSourceCount INT = 0;

-- Check Extended Events for monitoring/insights (exclude default system_health)
SELECT @CustomXECount = COUNT(*) FROM sys.dm_xe_sessions
WHERE name NOT LIKE 'system_health%'
  AND (name LIKE '%monitor%' OR name LIKE '%health%' OR name LIKE '%insight%' OR name LIKE '%telemetry%');

-- Check SQL Agent jobs for health/monitoring (on-prem/MI only)
SELECT @JobCount = COUNT(*) FROM msdb.dbo.sysjobs
WHERE name LIKE '%health%' OR name LIKE '%monitor%' OR name LIKE '%check%' OR name LIKE '%insight%';

-- Check external data sources for telemetry export
SELECT @ExtSourceCount = COUNT(*) FROM master.sys.external_data_sources
WHERE name LIKE '%monitor%' OR name LIKE '%telemetry%' OR name LIKE '%loganalytics%' OR name LIKE '%insight%';

-- Evaluate score
IF @CustomXECount > 0 OR @JobCount > 0 OR @ExtSourceCount > 0
    SET @Score = 2;
ELSE
BEGIN
    -- Check for default system_health
    IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = 'system_health')
        SET @Score = 1;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

-- NOTE: This script provides automated evidence. Full compliance requires human review.
SELECT @Result AS Result, @Score AS Score;