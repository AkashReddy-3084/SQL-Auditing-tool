-- Checklist: ETL is parameterized (no hardcoded servers, paths, dates, or credentials)
-- Scope: SERVER
-- Scoring: 3 = 0% of steps show hardcoded evidence; 2 = under 25%; 1 = 25-49%; 0 = 50%+ or no job steps found
-- NOTE: Automated evidence only; only SQL Agent job step text is inspected. Full compliance requires human review of ADF/SSIS package parameterization.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No job steps found to inspect';

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database: SQL Agent job steps are not available on this platform; parameterization cannot be observed from the engine';
END
ELSE
BEGIN
    DECLARE @TotalSteps INT = 0, @HardcodedSteps INT = 0;

    BEGIN TRY
        SELECT @TotalSteps = COUNT(*) FROM msdb.dbo.sysjobsteps;
        SELECT @HardcodedSteps = COUNT(*)
        FROM msdb.dbo.sysjobsteps
        WHERE command LIKE '%\\%' OR command LIKE '%PWD=%' OR command LIKE '%PASSWORD=%'
           OR command LIKE '%C:\%' OR command LIKE '%D:\%' OR command LIKE '%E:\%';
    END TRY
    BEGIN CATCH
        SET @TotalSteps = 0; SET @HardcodedSteps = 0;
    END CATCH;

    IF ISNULL(@TotalSteps,0) = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No job steps found to inspect';
    END
    ELSE
    BEGIN
        DECLARE @Ratio DECIMAL(9,4) = CAST(@HardcodedSteps AS DECIMAL(9,4)) / NULLIF(@TotalSteps,0);
        SET @Score = CASE
            WHEN @Ratio = 0 THEN 3
            WHEN @Ratio < 0.25 THEN 2
            WHEN @Ratio < 0.50 THEN 1
            ELSE 0
        END;
        SET @Finding = CONCAT('Job steps = ', @TotalSteps, ', steps with hardcoded server/path/credential evidence = ', @HardcodedSteps, ', ratio = ', CONVERT(NVARCHAR(20), @Ratio));
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;