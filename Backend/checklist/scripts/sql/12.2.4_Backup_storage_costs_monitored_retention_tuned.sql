-- Checklist: Backup storage costs monitored (retention tuned)
-- Scope: SERVER
-- Scoring: 0: No backup history or retention > 90 days (excessive storage cost). 1: Retention 61-90 days. 2: Retention 31-60 days or compression disabled. 3: Retention <= 30 days and compression enabled (optimal cost control).

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @OldestBackupDate DATETIME;
DECLARE @RetentionDays INT;
DECLARE @CompressionEnabled BIT = 0;
DECLARE @BackupCount INT = 0;

SET @DatabaseQueried = 'master';

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: Backup retention is platform-managed
    SET @Score = 3;
    SET @Finding = 'Backup retention is platform-managed (Azure SQL Database). Automated backups and retention policies are enforced by the service.';
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: Evaluate backup history and compression
    SELECT @OldestBackupDate = MIN(backup_start_date),
           @BackupCount = COUNT(*)
    FROM msdb.dbo.backupset
    WHERE type IN ('D', 'I', 'L');

    -- Check server-level compression default
    SELECT @CompressionEnabled = CASE WHEN CAST(value_in_use AS INT) = 1 THEN 1 ELSE 0 END
    FROM sys.configurations
    WHERE name = 'backup compression default';

    -- Override if any backup in history is compressed
    IF EXISTS (SELECT 1 FROM msdb.dbo.backupset WHERE is_compressed = 1)
        SET @CompressionEnabled = 1;

    IF @BackupCount = 0
    BEGIN
        SET @RetentionDays = 999;
        SET @Finding = 'No backup history found in msdb. Retention policy cannot be verified.';
    END
    ELSE
    BEGIN
        SET @RetentionDays = DATEDIFF(day, @OldestBackupDate, GETDATE());
        SET @Finding = 'Oldest backup age: ' + CAST(@RetentionDays AS NVARCHAR(10)) + ' days. Backup compression: ' + CASE WHEN @CompressionEnabled = 1 THEN 'Enabled' ELSE 'Disabled' END + '. Total backups in history: ' + CAST(@BackupCount AS NVARCHAR(10)) + '.';
    END

    IF @BackupCount = 0
        SET @Score = 0;
    ELSE IF @RetentionDays > 90
        SET @Score = 0;
    ELSE IF @RetentionDays > 60
        SET @Score = 1;
    ELSE IF @RetentionDays > 30 OR @CompressionEnabled = 0
        SET @Score = 2;
    ELSE
        SET @Score = 3;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;