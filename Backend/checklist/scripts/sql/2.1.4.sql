-- Checklist: Orchestration/dependency management exists (master package/pipeline or scheduler)
-- Scope: SERVER
-- Scoring: 3 = Multiple active jobs found; 2 = At least one active job found; 1 = Jobs exist but are disabled; 0 = No jobs found.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No orchestration evidence found';

DECLARE @JobCount INT;
DECLARE @ActiveJobCount INT;
DECLARE @JobList NVARCHAR(MAX);

-- We look into msdb to evaluate SQL Agent Jobs as the primary orchestration mechanism in SQL Server
SELECT 
    @JobCount = COUNT(*),
    @ActiveJobCount = SUM(CASE WHEN enabled = 1 THEN 1 ELSE 0 END),
    @JobList = STRING_AGG(CAST(name AS NVARCHAR(MAX)), ', ')
FROM msdb.dbo.sysjobs;

IF @JobCount = 0
BEGIN
    SET @Score = 0;
    SET @Finding = 'No SQL Agent jobs found; no evidence of orchestration.';
END
ELSE IF @ActiveJobCount >= 2
BEGIN
    SET @Score = 3;
    SET @Finding = 'Orchestration evidence found: ' + CAST(@ActiveJobCount AS NVARCHAR(10)) + ' active jobs. Jobs: ' + @JobList;
END
ELSE IF @ActiveJobCount = 1
BEGIN
    SET @Score = 2;
    SET @Finding = 'Minimal orchestration evidence: 1 active job found. Jobs: ' + @JobList;
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = 'Jobs exist but are all disabled. Jobs: ' + @JobList;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;