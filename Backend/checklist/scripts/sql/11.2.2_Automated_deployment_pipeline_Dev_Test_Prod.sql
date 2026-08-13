-- Checklist: Automated deployment pipeline (Dev → Test → Prod)
-- Scope: SERVER
-- Scoring: 0=No evidence, 1=Partial (Naming OR Jobs), 2=Strong Proxy (Naming AND Jobs), 3=Not achievable (External tool)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

DECLARE @ServerName NVARCHAR(256);
DECLARE @HasEnvNaming BIT = 0;
DECLARE @DeployJobCount INT = 0;

-- 1. Check for Environment Naming Convention (Proxy for Dev/Test/Prod separation)
SET @ServerName = CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(256));

IF @ServerName LIKE '%PROD%' OR @ServerName LIKE '%TEST%' OR @ServerName LIKE '%DEV%' OR @ServerName LIKE '%QA%'
BEGIN
    SET @HasEnvNaming = 1;
END

-- 2. Check for Automated Deployment Jobs (Proxy for CI/CD integration)
-- We look for jobs that suggest automated deployment (e.g., "Deploy", "Release", "Build")
SELECT @DeployJobCount = COUNT(*)
FROM msdb.dbo.sysjobs j
WHERE j.enabled = 1
  AND (
    j.name LIKE '%Deploy%' OR
    j.name LIKE '%Release%' OR
    j.name LIKE '%Build%' OR
    j.name LIKE '%CI/CD%'
  );

-- Scoring Logic
IF @HasEnvNaming = 1 AND @DeployJobCount > 0
BEGIN
    SET @Score = 2; -- Strong proxy evidence: Automation exists on a named environment
END
ELSE IF @HasEnvNaming = 1 OR @DeployJobCount > 0
BEGIN
    SET @Score = 1; -- Partial evidence: Either naming or automation found, but not both
END
ELSE
BEGIN
    SET @Score = 0; -- No evidence found
END

-- NOTE: This script provides automated evidence. Full compliance requires human review of the external CI/CD tool (e.g., Azure DevOps, Jenkins).
-- Score 3 is reserved for direct verification of the pipeline tool, which is not possible from within SQL Server.

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score;