-- Checklist: Rollback / recovery procedure defined and tested
-- Scope: SERVER
-- Scoring: 0=No evidence, 1=Backup history only, 2=Procedure defined but untested, 3=Procedure defined and recently tested
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @JobCount INT = 0;
DECLARE @TestedCount INT = 0;
DECLARE @BackupCount INT = 0;
DECLARE @ProcCount INT = 0;

-- Platform compatibility: msdb exists on-premises and in Azure SQL MI, but not in Azure SQL DB
IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    -- Check for rollback/recovery deployment jobs
    SELECT @JobCount = COUNT(*) FROM msdb.dbo.sysjobs
    WHERE name LIKE '%rollback%' OR name LIKE '%recovery%' OR name LIKE '%undeploy%' OR name LIKE '%downgrade%';

    -- Check if any of those jobs have recent successful runs (evidence of testing)
    -- step_id = 0 indicates the overall job run status, ensuring full job success is verified
    SELECT @TestedCount = COUNT(DISTINCT j.job_id)
    FROM msdb.dbo.sysjobs j
    INNER JOIN msdb.dbo.sysjobhistory h ON j.job_id = h.job_id
    WHERE (j.name LIKE '%rollback%' OR j.name LIKE '%recovery%' OR j.name LIKE '%undeploy%' OR j.name LIKE '%downgrade%')
      AND h.step_id = 0
      AND h.run_status = 1
      AND h.run_date >= CONVERT(INT, CONVERT(VARCHAR(8), DATEADD(DAY, -30, GETDATE()), 112));

    -- Check for recent full backups as proxy for recovery capability
    SELECT @BackupCount = COUNT(*) FROM msdb.dbo.backupset
    WHERE type = 'D' AND backup_finish_date >= DATEADD(DAY, -7, GETDATE());
END
ELSE
BEGIN
    -- Fallback for Azure SQL DB: check for rollback/recovery procs in current database
    SELECT @ProcCount = COUNT(*) FROM sys.procedures
    WHERE name LIKE '%rollback%' OR name LIKE '%recovery%' OR name LIKE '%undeploy%' OR name LIKE '%downgrade%';

    -- Azure SQL DB backup history fallback (if available)
    IF OBJECT_ID('sys.database_backup_history') IS NOT NULL
    BEGIN
        SELECT @BackupCount = COUNT(*) FROM sys.database_backup_history
        WHERE type = 'D' AND backup_finish_date >= DATEADD(DAY, -7, GETDATE());
    END
END

-- Scoring logic
IF @JobCount > 0 AND @TestedCount > 0 SET @Score = 3;
ELSE IF @JobCount > 0 SET @Score = 2;
ELSE IF @ProcCount > 0 SET @Score = 2;
ELSE IF @BackupCount > 0 SET @Score = 1;
ELSE SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;