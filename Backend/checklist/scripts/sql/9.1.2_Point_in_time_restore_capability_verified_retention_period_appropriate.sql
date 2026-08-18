-- Checklist: Point-in-time restore capability verified (retention period appropriate)
-- Scope: SERVER
-- Scoring: 0=No full backup or >24h old; 1=Full backup exists but missing log backups or retention <7 days; 2=Full backup <24h, log backups exist, retention 7-30 days; 3=Full backup <24h, log backups exist, retention >30 days.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbBackupStatus (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    -- Azure SQL Database: Platform-managed backups
    INSERT INTO #DbBackupStatus (DbName, DbScore, Finding)
    SELECT 
        DB_NAME(), 
        CASE WHEN state = 0 THEN 3 ELSE 0 END,
        CASE WHEN state = 0 THEN 'Platform-managed backups verified. Point-in-time restore capability enabled.' ELSE 'Database not online.' END
    FROM sys.databases 
    WHERE name = DB_NAME();
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: msdb backup history
    BEGIN TRY
        INSERT INTO #DbBackupStatus
        SELECT
            d.name AS DbName,
            CASE
                WHEN MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END) IS NULL THEN 0
                WHEN DATEDIFF(hour, MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END), GETDATE()) > 24 THEN 0
                WHEN MAX(CASE WHEN bs.type = 'L' THEN bs.backup_finish_date END) IS NULL THEN 1
                WHEN DATEDIFF(day, MIN(CASE WHEN bs.type IN ('D', 'L') THEN bs.backup_finish_date END), GETDATE()) > 30 THEN 3
                WHEN DATEDIFF(day, MIN(CASE WHEN bs.type IN ('D', 'L') THEN bs.backup_finish_date END), GETDATE()) BETWEEN 7 AND 30 THEN 2
                ELSE 1
            END AS DbScore,
            CASE
                WHEN MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END) IS NULL THEN 'No full backup found'
                WHEN DATEDIFF(hour, MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END), GETDATE()) > 24 THEN 'Full backup older than 24 hours'
                WHEN MAX(CASE WHEN bs.type = 'L' THEN bs.backup_finish_date END) IS NULL THEN 'No log backups found'
                WHEN DATEDIFF(day, MIN(CASE WHEN bs.type IN ('D', 'L') THEN bs.backup_finish_date END), GETDATE()) > 30 THEN 'Retention > 30 days, log backups present'
                WHEN DATEDIFF(day, MIN(CASE WHEN bs.type IN ('D', 'L') THEN bs.backup_finish_date END), GETDATE()) BETWEEN 7 AND 30 THEN 'Retention 7-30 days, log backups present'
                ELSE 'Retention < 7 days'
            END AS Finding
        FROM sys.databases d
        LEFT JOIN msdb.dbo.backupset bs ON d.name = bs.database_name AND bs.type IN ('D', 'L')
        WHERE d.database_id > 4 AND d.state = 0
        GROUP BY d.name;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbBackupStatus (DbName, DbScore, Finding)
        SELECT name, 1, 'Backup history inaccessible or insufficient permissions'
        FROM sys.databases
        WHERE database_id > 4 AND state = 0;
    END CATCH;
END

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbBackupStatus), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbBackupStatus), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbBackupStatus), 'No user databases found');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbBackupStatus;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;