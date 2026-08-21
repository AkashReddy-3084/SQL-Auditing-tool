SET NOCOUNT ON;

/* Checklist 9.1.2 - Point-in-time restore capability verified (retention period appropriate). Read-only. */

DECLARE @EngineEdition   INT           = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Now             DATETIME      = GETDATE();
DECLARE @Result          NVARCHAR(20);
DECLARE @Score           INT;
DECLARE @DatabaseQueried NVARCHAR(4000);
DECLARE @Finding         NVARCHAR(MAX);

CREATE TABLE #BackupHist
(
    DatabaseName     NVARCHAR(128) NULL,
    LastFullBackup   DATETIME      NULL,
    OldestFullBackup DATETIME      NULL,
    LastLogBackup    DATETIME      NULL
);

CREATE TABLE #PitrDb
(
    DatabaseName     SYSNAME      NOT NULL,
    RecoveryModel    NVARCHAR(60) NOT NULL,
    LastFullBackup   DATETIME     NULL,
    OldestFullBackup DATETIME     NULL,
    LastLogBackup    DATETIME     NULL
);

IF @EngineEdition = 5
BEGIN
    /* Azure SQL Database: PITR is platform-managed and msdb backup history is not queryable. */
    SET @Score           = 1;
    SET @DatabaseQueried = DB_NAME();
    SET @Finding         = N'Azure SQL Database detected (EngineEdition 5). Point-in-time restore is platform-managed and msdb backup history is not queryable, so the configured retention window cannot be read from the instance. Manually confirm the short-term retention policy (1-35 days) and any long-term retention policy for each database via the Azure portal, Get-AzSqlDatabaseBackupShortTermRetentionPolicy and Get-AzSqlDatabaseLongTermRetentionPolicy, and confirm it meets the required recovery point objective.';
END
ELSE
BEGIN
    /* The three-part msdb reference is isolated in a read-only dynamic SELECT so the batch still compiles where msdb is absent. */
    DECLARE @Sql NVARCHAR(MAX) =
        N'SELECT bs.database_name,
                 MAX(CASE WHEN bs.type = ''D'' THEN bs.backup_finish_date END) AS LastFullBackup,
                 MIN(CASE WHEN bs.type = ''D'' THEN bs.backup_finish_date END) AS OldestFullBackup,
                 MAX(CASE WHEN bs.type = ''L'' THEN bs.backup_finish_date END) AS LastLogBackup
          FROM ' + QUOTENAME(N'msdb') + N'.dbo.backupset AS bs
          WHERE bs.is_copy_only = 0
          GROUP BY bs.database_name;';

    INSERT INTO #BackupHist (DatabaseName, LastFullBackup, OldestFullBackup, LastLogBackup)
    EXEC sys.sp_executesql @Sql;

    INSERT INTO #PitrDb (DatabaseName, RecoveryModel, LastFullBackup, OldestFullBackup, LastLogBackup)
    SELECT d.name, d.recovery_model_desc, h.LastFullBackup, h.OldestFullBackup, h.LastLogBackup
    FROM sys.databases AS d
    LEFT JOIN #BackupHist AS h
           ON h.DatabaseName = d.name
    WHERE d.database_id > 4
      AND d.source_database_id IS NULL
      AND d.state = 0;

    DECLARE @Total          INT = 0;
    DECLARE @Simple         INT = 0;
    DECLARE @NoFull         INT = 0;
    DECLARE @NoLog          INT = 0;
    DECLARE @StaleFull      INT = 0;
    DECLARE @StaleLog       INT = 0;
    DECLARE @ShortRetention INT = 0;

    SELECT
        @Total          = COUNT(*),
        @Simple         = SUM(CASE WHEN p.RecoveryModel = N'SIMPLE' THEN 1 ELSE 0 END),
        @NoFull         = SUM(CASE WHEN p.LastFullBackup IS NULL THEN 1 ELSE 0 END),
        @NoLog          = SUM(CASE WHEN p.RecoveryModel <> N'SIMPLE' AND p.LastLogBackup IS NULL THEN 1 ELSE 0 END),
        @StaleFull      = SUM(CASE WHEN p.LastFullBackup IS NOT NULL AND p.LastFullBackup < DATEADD(DAY, -7, @Now) THEN 1 ELSE 0 END),
        @StaleLog       = SUM(CASE WHEN p.RecoveryModel <> N'SIMPLE' AND p.LastLogBackup IS NOT NULL AND p.LastLogBackup < DATEADD(HOUR, -24, @Now) THEN 1 ELSE 0 END),
        @ShortRetention = SUM(CASE WHEN p.RecoveryModel <> N'SIMPLE' AND p.OldestFullBackup IS NOT NULL AND p.OldestFullBackup > DATEADD(DAY, -14, @Now) THEN 1 ELSE 0 END)
    FROM #PitrDb AS p;

    SET @DatabaseQueried =
        ISNULL(STUFF((SELECT N', ' + p.DatabaseName
                      FROM #PitrDb AS p
                      ORDER BY p.DatabaseName
                      FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'msdb');

    DECLARE @Detail NVARCHAR(MAX) =
        ISNULL(STUFF((SELECT N'; ' + p.DatabaseName + N' [' + p.RecoveryModel
                             + N', last full: ' + ISNULL(CONVERT(NVARCHAR(19), p.LastFullBackup, 120), N'none')
                             + N', last log: '  + ISNULL(CONVERT(NVARCHAR(19), p.LastLogBackup, 120), N'none')
                             + N', history from: ' + ISNULL(CONVERT(NVARCHAR(19), p.OldestFullBackup, 120), N'none') + N']'
                      FROM #PitrDb AS p
                      WHERE p.RecoveryModel = N'SIMPLE'
                         OR p.LastFullBackup IS NULL
                         OR p.LastFullBackup < DATEADD(DAY, -7, @Now)
                         OR (p.RecoveryModel <> N'SIMPLE' AND (p.LastLogBackup IS NULL OR p.LastLogBackup < DATEADD(HOUR, -24, @Now)))
                         OR (p.RecoveryModel <> N'SIMPLE' AND p.OldestFullBackup IS NOT NULL AND p.OldestFullBackup > DATEADD(DAY, -14, @Now))
                      ORDER BY p.DatabaseName
                      FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'');

    IF @Total = 0
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'No online user databases are present on this instance, so point-in-time restore capability is not applicable.';
    END
    ELSE IF @Simple = @Total OR @NoFull = @Total
    BEGIN
        SET @Score   = 0;
        SET @Finding = N'No point-in-time restore capability exists: all ' + CAST(@Total AS NVARCHAR(10))
                     + N' user database(s) are either in SIMPLE recovery (' + CAST(@Simple AS NVARCHAR(10))
                     + N') or have no full backup history in msdb (' + CAST(@NoFull AS NVARCHAR(10))
                     + N'). Affected databases: ' + @Detail;
    END
    ELSE IF @Simple > 0 OR @NoFull > 0 OR @NoLog > 0
    BEGIN
        SET @Score   = 1;
        SET @Finding = N'Point-in-time restore is not available for every database: of ' + CAST(@Total AS NVARCHAR(10))
                     + N' user database(s), ' + CAST(@Simple AS NVARCHAR(10)) + N' use SIMPLE recovery, '
                     + CAST(@NoFull AS NVARCHAR(10)) + N' have no full backup history and '
                     + CAST(@NoLog AS NVARCHAR(10)) + N' have no transaction log backup at all. Affected databases: ' + @Detail;
    END
    ELSE IF @StaleFull > 0 OR @StaleLog > 0 OR @ShortRetention > 0
    BEGIN
        SET @Score   = 2;
        SET @Finding = N'All ' + CAST(@Total AS NVARCHAR(10))
                     + N' user database(s) are configured for point-in-time restore, but the restore window is degraded: '
                     + CAST(@StaleFull AS NVARCHAR(10)) + N' have a full backup older than 7 days, '
                     + CAST(@StaleLog AS NVARCHAR(10)) + N' have no log backup in the last 24 hours and '
                     + CAST(@ShortRetention AS NVARCHAR(10)) + N' have restorable full backup history shorter than 14 days. Affected databases: ' + @Detail;
    END
    ELSE
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'All ' + CAST(@Total AS NVARCHAR(10))
                     + N' user database(s) support point-in-time restore: each is in FULL or BULK_LOGGED recovery, has a non-copy-only full backup within the last 7 days, a transaction log backup within the last 24 hours, and restorable full backup history reaching back at least 14 days.';
    END
END

DROP TABLE #PitrDb;
DROP TABLE #BackupHist;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    CAST(@Result AS NVARCHAR(20))            AS Result,
    CAST(@Score AS INT)                      AS Score,
    CAST(@DatabaseQueried AS NVARCHAR(4000)) AS DatabaseQueried,
    CAST(@Finding AS NVARCHAR(MAX))          AS Finding;