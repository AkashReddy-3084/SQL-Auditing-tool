-- Checklist: Backups are encrypted
-- Scope: SERVER
-- Scoring: 0=Default OFF & no encrypted backups, 1=Default OFF but some encrypted backups exist, 2=Default ON but some unencrypted backups exist, 3=Default ON & all recent backups encrypted (or no backups to contradict)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DefaultOn BIT = 0;
DECLARE @EncryptedCount INT = 0;
DECLARE @TotalCount INT = 0;

-- Check server configuration for backup encryption default
SELECT @DefaultOn = CAST(value_in_use AS BIT)
FROM sys.configurations
WHERE name = 'backup encryption default';

-- Check backup history for encryption status (on-prem & SQL MI only)
IF OBJECT_ID('msdb.dbo.backupset') IS NOT NULL
BEGIN
    SELECT @EncryptedCount = COUNT(CASE WHEN is_encrypted = 1 THEN 1 END),
           @TotalCount = COUNT(*)
    FROM msdb.dbo.backupset
    WHERE type IN ('D', 'I', 'L') 
      AND backup_start_date >= DATEADD(day, -30, GETDATE());
END

-- Determine score based on configuration and backup history
IF @DefaultOn = 1
BEGIN
    IF @TotalCount = 0 SET @Score = 3; -- Default ON, no recent backups to contradict (common in PaaS/fresh instances)
    ELSE IF @EncryptedCount = @TotalCount SET @Score = 3;
    ELSE SET @Score = 2; -- Default ON, but some unencrypted backups exist in history
END
ELSE
BEGIN
    IF @TotalCount = 0 SET @Score = 0;
    ELSE IF @EncryptedCount > 0 SET @Score = 1; -- Default OFF, but some backups manually encrypted
    ELSE SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;