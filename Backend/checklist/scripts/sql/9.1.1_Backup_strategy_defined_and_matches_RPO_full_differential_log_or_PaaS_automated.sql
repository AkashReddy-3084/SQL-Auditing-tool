-- Checklist: Backup strategy defined and matches RPO (full/differential/log or PaaS automated)
-- Scope: SERVER
-- Scoring: 3=Complete strategy (Full+Diff+Log or PaaS automated); 2=Full+Log present but Diff missing/overdue; 1=Only Full backups or significant gaps; 0=No backups or SIMPLE recovery without backups.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbBackupStatus (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: Automated backups are inherent and managed by the platform
    INSERT INTO #DbBackupStatus (DbName, DbScore, Finding)
    VALUES (DB_NAME(), 3, 'PaaS automated backups enabled and managed by Azure');
END
ELSE
BEGIN
    -- SQL Server / Azure SQL Managed Instance
    INSERT INTO #DbBackupStatus (DbName, DbScore, Finding)
    SELECT
        d.name AS DbName,
        CASE
            WHEN d.recovery_model_desc = 'SIMPLE' THEN
                CASE
                    WHEN MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END) IS NULL THEN 0
                    WHEN DATEDIFF(day, MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END), GETDATE()) > 7 THEN 1
                    ELSE 3
                END
            ELSE
                CASE
                    WHEN MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END) IS NULL THEN 0
                    WHEN DATEDIFF(day, MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END), GETDATE()) > 7 THEN 1
                    WHEN MAX(CASE WHEN bs.type = 'I' THEN bs.backup_finish_date END) IS NULL THEN 2
                    WHEN DATEDIFF(hour, MAX(CASE WHEN bs.type = 'I' THEN bs.backup_finish_date END), GETDATE()) > 24 THEN 2
                    WHEN MAX(CASE WHEN bs.type = 'L' THEN bs.backup_finish_date END) IS NULL THEN 2
                    WHEN DATEDIFF(minute, MAX(CASE WHEN bs.type = 'L' THEN bs.backup_finish_date END), GETDATE()) > 60 THEN 2
                    ELSE 3
                END
        END AS DbScore,
        CASE
            WHEN d.recovery_model_desc = 'SIMPLE' THEN
                CASE
                    WHEN MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END) IS NULL THEN 'No full backup found'
                    WHEN DATEDIFF(day, MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END), GETDATE()) > 7 THEN 'Full backup older than 7 days'
                    ELSE 'Backup strategy compliant'
                END
            ELSE
                CASE
                    WHEN MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END) IS NULL THEN 'No full backup found'
                    WHEN DATEDIFF(day, MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END), GETDATE()) > 7 THEN 'Full backup older than 7 days'
                    WHEN MAX(CASE WHEN bs.type = 'I' THEN bs.backup_finish_date END) IS NULL THEN 'No differential backup found'
                    WHEN DATEDIFF(hour, MAX(CASE WHEN bs.type = 'I' THEN bs.backup_finish_date END), GETDATE()) > 24 THEN 'Differential backup older than 24 hours'
                    WHEN MAX(CASE WHEN bs.type = 'L' THEN bs.backup_finish_date END) IS NULL THEN 'No log backup found'
                    WHEN DATEDIFF(minute, MAX(CASE WHEN bs.type = 'L' THEN bs.backup_finish_date END), GETDATE()) > 60 THEN 'Log backup older than 60 minutes'
                    ELSE 'Backup strategy compliant'
                END
        END AS Finding
    FROM sys.databases d
    LEFT JOIN msdb.dbo.backupset bs
        ON d.name = bs.database_name
        AND bs.backup_finish_date >= DATEADD(day, -30, GETDATE())
    WHERE d.database_id > 4
      AND d.state = 0
    GROUP BY d.name, d.recovery_model_desc;
END

SET @DatabaseQueried = (
    SELECT STRING_AGG(DbName, ', ')
    FROM #DbBackupStatus
);

SET @Score = ISNULL(
    (SELECT MIN(DbScore) FROM #DbBackupStatus),
    0
);

SET @Finding = ISNULL(
    (
        SELECT STRING_AGG(DbName + ': ' + Finding, '; ')
        FROM #DbBackupStatus
        WHERE DbScore < 3
    ),
    'All databases have compliant backup strategies'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbBackupStatus;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;