-- Checklist: Backups are encrypted
-- Scope: SERVER
-- Scoring: 3=100% encrypted, 2=75-99%, 1=1-74%, 0=0% or no backups

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

SET @DatabaseQueried = 'master';

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: Backups are always encrypted by the platform
    SET @Score = 3;
    SET @Finding = 'Azure SQL Database automatically encrypts all backups.';
END
ELSE
BEGIN
    -- SQL Server / Azure SQL Managed Instance
    DECLARE @TotalDBs INT;
    DECLARE @EncryptedDBs INT;
    DECLARE @UnencryptedList NVARCHAR(MAX);

    WITH UserDBs AS (
        SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0
    ),
    LatestBackups AS (
        SELECT
            bs.database_name,
            bs.is_encrypted,
            ROW_NUMBER() OVER (PARTITION BY bs.database_name ORDER BY bs.backup_start_date DESC) as rn
        FROM msdb.dbo.backupset bs
        WHERE bs.type = 'D'
        AND EXISTS (SELECT 1 FROM UserDBs u WHERE u.name = bs.database_name)
    ),
    DBStatus AS (
        SELECT
            u.name AS DbName,
            CASE WHEN lb.is_encrypted = 1 THEN 1 ELSE 0 END AS IsEncrypted
        FROM UserDBs u
        LEFT JOIN LatestBackups lb ON u.name = lb.database_name AND lb.rn = 1
    )
    SELECT
        @TotalDBs = COUNT(*),
        @EncryptedDBs = SUM(IsEncrypted),
        @UnencryptedList = STRING_AGG(CASE WHEN IsEncrypted = 0 THEN DbName END, ', ')
    FROM DBStatus;

    IF @TotalDBs = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No user databases found.';
    END
    ELSE
    BEGIN
        DECLARE @Pct FLOAT = CAST(@EncryptedDBs AS FLOAT) / @TotalDBs * 100;

        IF @Pct = 100
            SET @Score = 3;
        ELSE IF @Pct >= 75
            SET @Score = 2;
        ELSE IF @Pct > 0
            SET @Score = 1;
        ELSE
            SET @Score = 0;

        IF @Score = 3
            SET @Finding = 'All user database backups are encrypted.';
        ELSE IF @EncryptedDBs = 0
            SET @Finding = 'No encrypted backups found. Unencrypted or missing backups for: ' + ISNULL(@UnencryptedList, 'All databases');
        ELSE
            SET @Finding = 'Partial encryption. Unencrypted backups for: ' + ISNULL(@UnencryptedList, 'None');
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;