-- Checklist: Backup failures alerted and monitored
-- Scope: SERVER
-- Scoring: 2 = backup job steps and enabled operators exist; 1 = backup steps or operators exist; 0 = no backup monitoring evidence
-- NOTE: Automated evidence only; confirming alert delivery and failure coverage requires human review.

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'Backup monitoring metadata could not be evaluated';
DECLARE @BackupSteps INT = 0;
DECLARE @Operators INT = 0;

BEGIN TRY
    SELECT @BackupSteps = COUNT(*) FROM msdb.dbo.sysjobsteps WHERE command LIKE '%BACKUP%';
    SELECT @Operators = COUNT(*) FROM msdb.dbo.sysoperators WHERE enabled = 1;
    SET @Score = CASE WHEN @BackupSteps > 0 AND @Operators > 0 THEN 2 WHEN @BackupSteps > 0 OR @Operators > 0 THEN 1 ELSE 0 END;
    SET @Finding = N'backup_steps=' + CONVERT(NVARCHAR(20), @BackupSteps) + N', operators=' + CONVERT(NVARCHAR(20), @Operators);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read backup monitoring metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;