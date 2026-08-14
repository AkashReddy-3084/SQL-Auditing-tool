-- Checklist: Backup storage costs monitored (retention tuned)
-- Scope: SERVER
-- Scoring: 0 = No backup history found; 1 = Backups exist but are very old (>60 days) with no cleanup job; 2 = Cleanup job exists OR backups are recent (<30 days), but not both (or Azure SQL DB where retention is cloud-managed); 3 = Automated cleanup job exists AND oldest backup is within retention window (<30 days), indicating tuned retention.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @OldestBackupDate DATETIME;
DECLARE @CleanupJobExists BIT = 0;
DECLARE @MsdbAvailable BIT = 0;

SELECT @MsdbAvailable = CASE WHEN OBJECT_ID('msdb.dbo.backupset') IS NOT NULL THEN 1 ELSE 0 END;

IF @MsdbAvailable = 1
BEGIN
    -- Check for automated backup cleanup/retention jobs
    IF EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobs j
        INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
        WHERE j.enabled = 1
        AND (
            j.name LIKE '%cleanup%' OR j.name LIKE '%delete%' OR j.name LIKE '%retention%'
            OR js.command LIKE '%cleanup%' OR js.command LIKE '%delete%' OR js.command LIKE '%retention%'
            OR js.command LIKE '%xp_delete_file%' OR js.command LIKE '%sp_delete_backuphistory%'
        )
    )
        SET @CleanupJobExists = 1;

    -- Find the oldest backup in history
    SELECT @OldestBackupDate = MIN(bs.backup_start_date)
    FROM msdb.dbo.backupset bs
    WHERE bs.type IN ('D', 'I', 'L');

    IF @OldestBackupDate IS NULL
        SET @Score = 0;
    ELSE
    BEGIN
        DECLARE @DaysSinceOldestBackup INT = DATEDIFF(DAY, @OldestBackupDate, GETDATE());
        
        IF @CleanupJobExists = 1 AND @DaysSinceOldestBackup <= 30
            SET @Score = 3;
        ELSE IF @CleanupJobExists = 1 OR @DaysSinceOldestBackup <= 30
            SET @Score = 2;
        ELSE IF @DaysSinceOldestBackup > 60
            SET @Score = 1;
        ELSE
            SET @Score = 2;
    END
END
ELSE
BEGIN
    -- Azure SQL DB: Backup retention is managed by the platform based on service tier.
    -- We cannot query msdb, so we assign partial credit assuming cloud-managed retention.
    SET @Score = 2;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;