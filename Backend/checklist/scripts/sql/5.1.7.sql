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