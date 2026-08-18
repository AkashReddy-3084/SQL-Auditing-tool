-- Checklist: Orchestration/dependency management exists (master package/pipeline or scheduler)
-- Scope: SERVER
-- Scoring: 3=Clear scheduler/orchestrator (multi-step/ETL jobs); 2=Scheduler exists but lacks clear orchestration pattern; 1=No scheduler, but procedure dependency chains found; 0=No evidence of orchestration or scheduling.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @JobCount INT = 0;
DECLARE @OrchestratedJobCount INT = 0;
DECLARE @ProcDepCount INT = 0;

-- Evaluate SQL Agent Jobs (not available in Azure SQL Database)
IF @EngineEdition <> 5
BEGIN
    SELECT @JobCount = COUNT(*) 
    FROM msdb.dbo.sysjobs 
    WHERE enabled = 1;

    SELECT @OrchestratedJobCount = COUNT(DISTINCT j.job_id)
    FROM msdb.dbo.sysjobs j
    INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
    WHERE j.enabled = 1
      AND (
          (SELECT COUNT(*) FROM msdb.dbo.sysjobsteps js2 WHERE js2.job_id = j.job_id) > 1
          OR js.command LIKE '%dtexec%'
          OR js.command LIKE '%SSIS%'
          OR js.command LIKE '%ETL%'
          OR js.subsystem IN ('SSIS', 'CmdExec', 'TSQL')
      );
END

-- Fallback: Check for stored procedure dependencies as proxy for orchestration
SELECT @ProcDepCount = COUNT(DISTINCT p.OBJECT_ID)
FROM sys.procedures p
WHERE EXISTS (
    SELECT 1 FROM sys.sql_expression_dependencies d
    WHERE d.referencing_id = p.OBJECT_ID
      AND d.referenced_id IN (SELECT OBJECT_ID FROM sys.procedures)
);

-- Determine Score and Finding
IF @OrchestratedJobCount > 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'Orchestration/scheduler detected: ' + CAST(@OrchestratedJobCount AS NVARCHAR) + ' SQL Agent job(s) with multi-step or ETL/SSIS configuration found.';
END
ELSE IF @JobCount > 0
BEGIN
    SET @Score = 2;
    SET @Finding = 'Scheduler detected: ' + CAST(@JobCount AS NVARCHAR) + ' SQL Agent job(s) found, but no clear multi-step or ETL orchestration pattern identified.';
END
ELSE IF @ProcDepCount > 0
BEGIN
    SET @Score = 1;
    SET @Finding = 'No SQL Agent scheduler found. Proxy evidence: ' + CAST(@ProcDepCount AS NVARCHAR) + ' stored procedure(s) with dependency chains detected.';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = 'No evidence of orchestration, dependency management, or scheduler found.';
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;