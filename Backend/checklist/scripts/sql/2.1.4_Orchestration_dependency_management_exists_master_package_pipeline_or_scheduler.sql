-- Checklist: Orchestration/dependency management exists (master package/pipeline or scheduler)
-- Scope: SERVER
-- Scoring: 0=No evidence, 1=Basic scheduler/jobs found, 2=Multi-step jobs or orchestrator procs found, 3=Robust orchestration with dependency management
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @JobCount INT = 0;
DECLARE @MultiStepJobCount INT = 0;
DECLARE @OrchestratorProcCount INT = 0;
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

-- Check SQL Agent Jobs (On-prem / MI only; gracefully degrades for Azure SQL DB)
IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    SELECT @JobCount = COUNT(*)
    FROM msdb.dbo.sysjobs j
    WHERE j.enabled = 1
      AND (j.name LIKE '%ETL%' OR j.name LIKE '%Load%' OR j.name LIKE '%Sync%' OR j.name LIKE '%Master%' OR j.name LIKE '%Orchestrator%' OR j.name LIKE '%Pipeline%');

    SELECT @MultiStepJobCount = COUNT(*)
    FROM (
        SELECT j.job_id
        FROM msdb.dbo.sysjobs j
        INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
        WHERE j.enabled = 1
          AND (j.name LIKE '%ETL%' OR j.name LIKE '%Load%' OR j.name LIKE '%Sync%' OR j.name LIKE '%Master%' OR j.name LIKE '%Orchestrator%' OR j.name LIKE '%Pipeline%')
        GROUP BY j.job_id
        HAVING COUNT(js.step_id) > 1
    ) AS MultiStep;
END

-- Check user databases for orchestrator/master procedures
CREATE TABLE #ProcResults (DbName NVARCHAR(256), ProcCount INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        SELECT COUNT(*) FROM sys.procedures p
        WHERE p.name LIKE ''%Master%'' OR p.name LIKE ''%Orchestrator%'' OR p.name LIKE ''%Pipeline%'' OR p.name LIKE ''%ETL%'';';
        INSERT INTO #ProcResults (DbName, ProcCount)
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #ProcResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SELECT @OrchestratorProcCount = ISNULL(SUM(ProcCount), 0) FROM #ProcResults;
DROP TABLE #ProcResults;

-- Scoring logic (ordered highest to lowest to prevent short-circuit)
IF @MultiStepJobCount > 0 AND @OrchestratorProcCount > 0
    SET @Score = 3;
ELSE IF @MultiStepJobCount > 0 OR @OrchestratorProcCount > 0
    SET @Score = 2;
ELSE IF @JobCount > 0
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;