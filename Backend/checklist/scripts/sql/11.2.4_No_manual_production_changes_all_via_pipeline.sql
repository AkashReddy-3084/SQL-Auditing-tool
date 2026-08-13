-- Checklist: No manual production changes — all via pipeline
-- Scope: SERVER
-- Scoring: 0=No audit or CI/CD evidence; 1=Pipeline jobs found but no change tracking; 2=Audit/Extended Events enabled for change tracking (proxy evidence); 3=Not achievable for process verification
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @AuditEnabled BIT = 0;
DECLARE @PipelineJobs BIT = 0;

-- Check for enabled Server Audit
IF EXISTS (SELECT 1 FROM sys.server_audits WHERE is_state_enabled = 1) SET @AuditEnabled = 1;

-- Check for enabled Database Audit
IF @AuditEnabled = 0
BEGIN
    IF EXISTS (SELECT 1 FROM sys.database_audits WHERE is_state_enabled = 1) SET @AuditEnabled = 1;
END

-- Check for Extended Events capturing changes (platform safe)
IF @AuditEnabled = 0 AND OBJECT_ID('sys.dm_xe_sessions') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name LIKE '%ddl%' OR name LIKE '%object%' OR name LIKE '%change%') SET @AuditEnabled = 1;
END

-- Check for CI/CD pipeline jobs in SQL Agent
IF EXISTS (
    SELECT 1 FROM msdb.dbo.sysjobs
    WHERE enabled = 1
      AND (name LIKE '%deploy%' OR name LIKE '%pipeline%' OR name LIKE '%release%' OR name LIKE '%azure-devops%' OR name LIKE '%github%' OR name LIKE '%gitlab%')
) SET @PipelineJobs = 1;

-- Calculate score based on proxy evidence
IF @AuditEnabled = 1 SET @Score = 2;
ELSE IF @PipelineJobs = 1 SET @Score = 1;
ELSE SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

-- NOTE: This script provides automated evidence. Full compliance requires human review.
SELECT @Result AS Result, @Score AS Score;