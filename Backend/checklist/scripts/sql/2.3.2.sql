-- Checklist: Failed loads are restartable from point of failure (not full re-run)
-- Scope: SERVER
-- Scoring: 3 = retry steps and checkpoint metadata are both present; 2 = retry or checkpoint evidence is present; 1 = load steps exist without restart evidence; 0 = no load-step evidence
-- NOTE: Automated evidence only; restartability requires validating operational behavior.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'Load restartability metadata could not be evaluated';
DECLARE @RetrySteps INT = 0;
DECLARE @Steps INT = 0;
DECLARE @CheckpointColumns INT = 0;

BEGIN TRY
    SELECT @RetrySteps = COUNT(*) FROM msdb.dbo.sysjobsteps WHERE retry_attempts > 0;
    SELECT @Steps = COUNT(*) FROM msdb.dbo.sysjobsteps;
    SELECT @CheckpointColumns = COUNT(*)
    FROM sys.columns AS c
    JOIN sys.tables AS t ON t.object_id = c.object_id
    WHERE t.is_ms_shipped = 0
      AND (c.name LIKE '%status%' OR c.name LIKE '%state%' OR c.name LIKE '%checkpoint%')
      AND (t.name LIKE '%log%' OR t.name LIKE '%batch%' OR t.name LIKE '%control%' OR t.name LIKE '%run%');

    SET @Score = CASE WHEN @RetrySteps > 0 AND @CheckpointColumns > 0 THEN 3
                      WHEN @RetrySteps > 0 OR @CheckpointColumns > 0 THEN 2
                      WHEN @Steps > 0 THEN 1 ELSE 0 END;
    SET @Finding = N'retry_steps=' + CONVERT(NVARCHAR(20), @RetrySteps) + N', steps=' + CONVERT(NVARCHAR(20), @Steps) + N', checkpoint_cols=' + CONVERT(NVARCHAR(20), @CheckpointColumns);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read load restartability metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;