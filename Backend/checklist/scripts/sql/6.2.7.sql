-- Checklist: Backups are encrypted
-- Scope: SERVER
-- Scoring: 3 = 100% of databases' most recent backups are encrypted (or Azure SQL DB platform-managed); 2 = 50-99%; 1 = under 50%; 0 = no backup history found

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX);

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Score = 3;
    SET @Finding = 'Azure SQL Database: backups are platform-managed and encrypted by default';
END
ELSE
BEGIN
    DECLARE @TotalDbCount INT, @EncryptedDbCount INT;

    IF OBJECT_ID('msdb.dbo.backupset') IS NOT NULL
    BEGIN
        SELECT @TotalDbCount = COUNT(DISTINCT database_name)
        FROM msdb.dbo.backupset bs
        WHERE bs.backup_finish_date = (
            SELECT MAX(bs2.backup_finish_date) FROM msdb.dbo.backupset bs2 WHERE bs2.database_name = bs.database_name
        )
        AND bs.database_name IN (SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0);

        SELECT @EncryptedDbCount = COUNT(DISTINCT database_name)
        FROM msdb.dbo.backupset bs
        WHERE bs.backup_finish_date = (
            SELECT MAX(bs2.backup_finish_date) FROM msdb.dbo.backupset bs2 WHERE bs2.database_name = bs.database_name
        )
        AND bs.database_name IN (SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0)
        AND bs.is_backup_encrypted = 1;
    END

    SET @Score = CASE WHEN ISNULL(@TotalDbCount,0) = 0 THEN 0
                      WHEN @EncryptedDbCount = @TotalDbCount THEN 3
                      WHEN (CAST(ISNULL(@EncryptedDbCount,0) AS DECIMAL(9,4)) / NULLIF(@TotalDbCount,0)) >= 0.50 THEN 2
                      ELSE 1 END;
    SET @Finding = CASE WHEN ISNULL(@TotalDbCount,0) = 0 THEN 'No backup history found for any user database'
                        ELSE CONCAT('Databases with backup history = ', @TotalDbCount, ', most recent backup encrypted = ', ISNULL(@EncryptedDbCount,0)) END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;