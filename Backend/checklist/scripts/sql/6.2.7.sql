-- Checklist: Backups are encrypted
-- Scope: SERVER
-- Scoring: 3 = all backup history rows are encrypted and have an encryptor; 2 = at least 75% are encrypted; 1 = some but less than 75% are encrypted; 0 = no backup history or evidence is unavailable
-- NOTE: Automated evidence covers backup history; encryption requirements for future backups and key ownership require human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'Backup encryption evidence unavailable';
DECLARE @BackupCount INT = 0;
DECLARE @EncryptedBackupCount INT = 0;
DECLARE @AlgorithmCount INT = 0;
DECLARE @EncryptorCount INT = 0;
DECLARE @EncryptedPercent DECIMAL(6, 2) = 0.00;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT
        @BackupCount = COUNT(*),
        @EncryptedBackupCount = ISNULL(SUM(CASE WHEN key_algorithm IS NOT NULL THEN 1 ELSE 0 END), 0),
        @AlgorithmCount = COUNT(DISTINCT key_algorithm),
        @EncryptorCount = ISNULL(SUM(CASE WHEN encryptor_type IS NOT NULL THEN 1 ELSE 0 END), 0)
    FROM msdb.dbo.backupset;
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

SET @EncryptedPercent = CASE
    WHEN @BackupCount = 0 THEN 0.00
    ELSE CONVERT(DECIMAL(6, 2), 100.0 * @EncryptedBackupCount / NULLIF(@BackupCount, 0))
END;

SET @Score = CASE
    WHEN @ReadError = 1 OR @BackupCount = 0 THEN 0
    WHEN @EncryptedBackupCount = @BackupCount AND @EncryptorCount = @BackupCount THEN 3
    WHEN @EncryptedPercent >= 75.00 THEN 2
    WHEN @EncryptedBackupCount > 0 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'backup history rows = ', @BackupCount,
    N'; encrypted rows = ', @EncryptedBackupCount,
    N'; encrypted percentage = ', @EncryptedPercent, N'%',
    N'; distinct key algorithms = ', @AlgorithmCount,
    N'; rows with encryptor = ', @EncryptorCount,
    CASE WHEN @ReadError = 1 THEN N'; backup history could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
