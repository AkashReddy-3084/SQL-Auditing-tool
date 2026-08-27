-- Checklist: Retry logic exists for transient failures
-- Scope: SERVER
-- Scoring: 3 = Agent retry steps and T-SQL retry modules exist; 2 = one retry mechanism exists; 1 = load steps exist without retry logic; 0 = no executable load evidence
-- NOTE: Automated evidence only; retry safety and transient-error classification require human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'Retry metadata could not be evaluated';
DECLARE @RetrySteps INT = 0;
DECLARE @Steps INT = 0;
DECLARE @RetryModules INT = 0;

BEGIN TRY
    SELECT @RetrySteps = COUNT(*) FROM msdb.dbo.sysjobsteps WHERE retry_attempts > 0;
    SELECT @Steps = COUNT(*) FROM msdb.dbo.sysjobsteps;
    SELECT @RetryModules = COUNT(*)
    FROM sys.sql_modules
    WHERE definition LIKE '%WAITFOR DELAY%'
       OR (definition LIKE '%WHILE%' AND definition LIKE '%retry%');

    SET @Score = CASE WHEN @RetrySteps > 0 AND @RetryModules > 0 THEN 3
                      WHEN @RetrySteps > 0 OR @RetryModules > 0 THEN 2
                      WHEN @Steps > 0 THEN 1 ELSE 0 END;
    SET @Finding = N'retry_steps=' + CONVERT(NVARCHAR(20), @RetrySteps) + N', steps=' + CONVERT(NVARCHAR(20), @Steps) + N', retry_modules=' + CONVERT(NVARCHAR(20), @RetryModules);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read retry metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;