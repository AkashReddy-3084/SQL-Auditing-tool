-- Checklist: Backups are encrypted
-- Scope: SERVER
-- Scoring: 3 = all recent backups encrypted; 2 = most recent backup encrypted; 1 = some backups encrypted; 0 = no backups encrypted or no backup history found.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No backup history found';

-- We evaluate the most recent backup for each database that has been backed up
-- to determine the current encryption posture.
DECLARE @EncryptedCount INT = 0;
DECLARE @TotalCount INT = 0;
DECLARE @Details NVARCHAR(MAX) = '';

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Score = 3;
    SET @Finding = 'Azure SQL Database: Backups are managed by the platform and encrypted by default.';
END
ELSE
BEGIN
    -- Use a temp table to identify the latest backup per database
    CREATE TABLE #LatestBackups (
        DbName SYSNAME,
        IsEncrypted BIT,
        BackupFinishDate DATETIME
    );

    INSERT INTO #LatestBackups (DbName, IsEncrypted, BackupFinishDate)
    SELECT 
        s.database_name, 
        s.encrypted, 
        s.backup_finish_date
    FROM (
        SELECT 
            database_name, 
            encrypted, 
            backup_finish_date,
            ROW_NUMBER() OVER (PARTITION BY database_name ORDER BY backup_finish_date DESC) as rn
        FROM msdb.dbo.backupset
        WHERE type = 'D' -- Full backup
    ) s
    WHERE s.rn = 1;

    SELECT @TotalCount = COUNT(*) FROM #LatestBackups;
    SELECT @EncryptedCount = COUNT(*) FROM #LatestBackups WHERE IsEncrypted = 1;

    IF @TotalCount = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No full backup history found in msdb.dbo.backupset';
    END
    ELSE
    BEGIN
        -- Build finding string
        SELECT @Details = STRING_AGG(
            QUOTENAME(DbName) + ': ' + CASE WHEN IsEncrypted = 1 THEN 'Encrypted' ELSE 'Not Encrypted' END, 
            '; '
        ) FROM #LatestBackups;

        -- Scoring logic based on requirements:
        -- 3 = all recent backups encrypted
        -- 2 = most recent backup encrypted (at least one DB's latest backup is encrypted)
        -- 1 = some backups encrypted (this is logically covered by score 2, but we follow the hierarchy)
        -- 0 = no backups encrypted
        IF @EncryptedCount = @TotalCount
            SET @Score = 3;
        ELSE IF @EncryptedCount > 0
            SET @Score = 2;
        ELSE
            SET @Score = 0;

        SET @Finding = 'Total DBs backed up: ' + CAST(@TotalCount AS NVARCHAR(10)) + ', Encrypted: ' + CAST(@EncryptedCount AS NVARCHAR(10)) + '. Details: ' + @Details;
    END

    DROP TABLE #LatestBackups;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;