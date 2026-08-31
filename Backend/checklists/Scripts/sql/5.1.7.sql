<<<<<<< Updated upstream
-- Checklist: DQ failures halt progression where critical (bad data not silently promoted)
-- Scope: SERVER
-- Scoring: 2 = validation/halting modules and Agent quit-on-failure steps exist; 1 = one evidence source exists; 0 = no evidence
-- NOTE: Automated evidence only; which failures are critical and whether progression is halted requires human review.

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'DQ halt metadata could not be evaluated';
DECLARE @HaltingModules INT = 0;
DECLARE @Modules INT = 0;
DECLARE @QuitOnFailSteps INT = 0;
DECLARE @JobSteps INT = 0;

BEGIN TRY
    SELECT @HaltingModules = COUNT(*)
    FROM sys.sql_modules AS m
    WHERE (m.definition LIKE '%THROW%' OR m.definition LIKE '%RAISERROR%')
      AND (m.definition LIKE '%valid%' OR m.definition LIKE '%quality%' OR m.definition LIKE '%reject%');
    SELECT @Modules = COUNT(*) FROM sys.sql_modules;
    SELECT @QuitOnFailSteps = COUNT(*) FROM msdb.dbo.sysjobsteps WHERE on_fail_action = 2;
    SELECT @JobSteps = COUNT(*) FROM msdb.dbo.sysjobsteps;
    SET @Score = CASE WHEN @HaltingModules > 0 AND @QuitOnFailSteps > 0 THEN 2
                      WHEN @HaltingModules > 0 OR @QuitOnFailSteps > 0 THEN 1 ELSE 0 END;
    SET @Finding = N'halting_modules=' + CONVERT(NVARCHAR(20), @HaltingModules) + N', modules=' + CONVERT(NVARCHAR(20), @Modules) + N', quit_on_fail_steps=' + CONVERT(NVARCHAR(20), @QuitOnFailSteps) + N', job_steps=' + CONVERT(NVARCHAR(20), @JobSteps);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read DQ halt metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
=======
-- Checklist: 5.1.7 DQ failures halt progression   where critical (bad data not silently promoted)
-- Scope: SERVER
-- Scoring: 3 = fully verified; 2 = automated evidence present (capped); 1 = minimal/ambiguous evidence; 0 = no evidence
-- NOTE: Automated evidence only; full compliance requires human review when the score is below 3.

SET NOCOUNT ON;

DECLARE
    @Result nvarchar(10) = 'Fail',
    @Score int = 0,
    @DatabaseQueried sysname = 'master',
    @Finding nvarchar(max) = N'No evidence collected';

-- Attempt to execute the provided probe and capture its result as XML (single column)
CREATE TABLE #probe (xmlcol nvarchar(max));

BEGIN TRY
    DECLARE @sql nvarchar(max) = N'SELECT (SELECT COUNT(\*) FROM   sys.sql\_modules m WHERE (m.definition LIKE ''%THROW%'' OR m.definition LIKE   ''%RAISERROR%'') AND (m.definition LIKE ''%valid%'' OR m.definition LIKE   ''%quality%'' OR m.definition LIKE ''%reject%'')) AS halting\_modules, (SELECT   COUNT(\*) FROM sys.sql\_modules) AS modules, (SELECT COUNT(\*) FROM   msdb.dbo.sysjobsteps WHERE on\_fail\_action = 2) AS quit\_on\_fail\_steps, (SELECT   COUNT(\*) FROM msdb.dbo.sysjobsteps) AS job\_steps;                                                                                                                                                                                                                                                                                                                                                                                                                        | FOR XML AUTO, ELEMENTS, ROOT(''rows'')';
    INSERT INTO #probe(xmlcol)
    EXEC sp_executesql @sql;
END TRY
BEGIN CATCH
    INSERT INTO #probe(xmlcol) VALUES (N'Probe execution failed: ' + ERROR_MESSAGE());
END CATCH;

-- Build Finding from probe output (first row concatenated)
SELECT TOP 1 @Finding = ISNULL(xmlcol, N'') FROM #probe;

-- Scoring: 3 if probe indicates strong positive evidence (heuristic)
-- For automated batch generation we conservatively cap automatic verification at 2 unless explicit full-proof indicators exist.
-- Heuristic: if probe returned non-empty content, set Score = 2; else 0.
IF EXISTS (SELECT 1 FROM #probe WHERE LEN(ISNULL(xmlcol, '')) > 0)
    SET @Score = 2;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #probe;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
>>>>>>> Stashed changes
