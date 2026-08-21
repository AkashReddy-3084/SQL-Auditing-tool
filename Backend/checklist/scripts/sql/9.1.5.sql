/* Checklist 9.1.5 - Backups stored redundantly / geo-redundant where required
   Scope: SERVER. Read-only. Proxy evidence = backup destination classes in msdb backup history. */
SET NOCOUNT ON;

DECLARE @Result           NVARCHAR(50);
DECLARE @Score            INT            = 0;
DECLARE @DatabaseQueried  NVARCHAR(256)  = N'msdb';
DECLARE @Finding          NVARCHAR(MAX)  = N'';
DECLARE @EngineEdition    INT            = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @LookbackDays     INT            = 90;

IF OBJECT_ID('tempdb..#UserDatabases') IS NOT NULL DROP TABLE #UserDatabases;
CREATE TABLE #UserDatabases
(
    DatabaseName SYSNAME NOT NULL
);

IF OBJECT_ID('tempdb..#BackupTargets') IS NOT NULL DROP TABLE #BackupTargets;
CREATE TABLE #BackupTargets
(
    DatabaseName     SYSNAME  NOT NULL,
    LastFullBackup   DATETIME NULL,
    UrlDeviceCount   INT      NOT NULL,
    UncDeviceCount   INT      NOT NULL,
    TapeDeviceCount  INT      NOT NULL,
    LocalDeviceCount INT      NOT NULL
);

DECLARE @TotalDbs       INT = 0;
DECLARE @WithHistory    INT = 0;
DECLARE @RedundantDbs   INT = 0;
DECLARE @LocalOnlyDbs   INT = 0;
DECLARE @NoHistoryDbs   INT = 0;
DECLARE @UrlDbs         INT = 0;
DECLARE @UncDbs         INT = 0;
DECLARE @TapeDbs        INT = 0;
DECLARE @LocalOnlyList  NVARCHAR(MAX) = N'';
DECLARE @NoHistoryList  NVARCHAR(MAX) = N'';

IF @EngineEdition = 5
BEGIN
    SET @Score           = 1;
    SET @DatabaseQueried = DB_NAME();
    SET @Finding         = N'MANUAL VERIFICATION REQUIRED: Azure SQL Database detected (EngineEdition 5). Backups are platform managed and msdb backup history is not exposed, so the backup storage redundancy setting (LRS / ZRS / GRS / GZRS) cannot be read through T-SQL. Confirm the configured backup storage redundancy for this database and its logical server in the Azure portal, Azure CLI or ARM template and compare it against the documented geo-redundancy / RPO requirement.';
END
ELSE IF DB_ID('msdb') IS NULL
BEGIN
    SET @Score   = 1;
    SET @Finding = N'MANUAL VERIFICATION REQUIRED: the msdb database is not present or not accessible on this instance, so backup destination history could not be inspected. Verify where database backups are written, and the redundancy of that storage, from the backup tooling and storage configuration.';
END
ELSE IF HAS_PERMS_BY_NAME(N'msdb.dbo.backupset', N'OBJECT', N'SELECT') = 0
     OR HAS_PERMS_BY_NAME(N'msdb.dbo.backupmediafamily', N'OBJECT', N'SELECT') = 0
BEGIN
    SET @Score   = 1;
    SET @Finding = N'MANUAL VERIFICATION REQUIRED: the audit login does not have SELECT permission on msdb.dbo.backupset and/or msdb.dbo.backupmediafamily, so backup destinations could not be classified. Grant read access to msdb backup history (for example the db_datareader role in msdb) and re-run, or evidence backup storage redundancy from the backup tooling.';
END
ELSE
BEGIN
    INSERT INTO #UserDatabases (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.source_database_id IS NULL;

    INSERT INTO #BackupTargets (DatabaseName, LastFullBackup, UrlDeviceCount, UncDeviceCount, TapeDeviceCount, LocalDeviceCount)
    SELECT
        bs.database_name,
        MAX(bs.backup_finish_date),
        SUM(CASE WHEN bmf.device_type IN (9, 109)
                   OR bmf.physical_device_name LIKE 'https://%'
                   OR bmf.physical_device_name LIKE 'http://%'  THEN 1 ELSE 0 END),
        SUM(CASE WHEN bmf.physical_device_name LIKE '\\%'       THEN 1 ELSE 0 END),
        SUM(CASE WHEN bmf.device_type IN (5, 105)               THEN 1 ELSE 0 END),
        SUM(CASE WHEN bmf.physical_device_name LIKE '[A-Z]:\%'  THEN 1 ELSE 0 END)
    FROM msdb.dbo.backupset AS bs
    INNER JOIN msdb.dbo.backupmediafamily AS bmf
        ON bmf.media_set_id = bs.media_set_id
    INNER JOIN #UserDatabases AS ud
        ON ud.DatabaseName = bs.database_name
    WHERE bs.type = 'D'
      AND bs.backup_finish_date >= DATEADD(DAY, -@LookbackDays, GETDATE())
    GROUP BY bs.database_name;

    SELECT @TotalDbs = COUNT(*) FROM #UserDatabases;
    SELECT @WithHistory = COUNT(*) FROM #BackupTargets;

    SELECT @RedundantDbs = COUNT(*)
    FROM #BackupTargets
    WHERE UrlDeviceCount > 0 OR UncDeviceCount > 0 OR TapeDeviceCount > 0;

    SELECT @LocalOnlyDbs = COUNT(*)
    FROM #BackupTargets
    WHERE UrlDeviceCount = 0 AND UncDeviceCount = 0 AND TapeDeviceCount = 0;

    SELECT @UrlDbs  = SUM(CASE WHEN UrlDeviceCount  > 0 THEN 1 ELSE 0 END),
           @UncDbs  = SUM(CASE WHEN UncDeviceCount  > 0 THEN 1 ELSE 0 END),
           @TapeDbs = SUM(CASE WHEN TapeDeviceCount > 0 THEN 1 ELSE 0 END)
    FROM #BackupTargets;

    SET @UrlDbs  = ISNULL(@UrlDbs, 0);
    SET @UncDbs  = ISNULL(@UncDbs, 0);
    SET @TapeDbs = ISNULL(@TapeDbs, 0);
    SET @NoHistoryDbs = @TotalDbs - @WithHistory;

    SET @LocalOnlyList = ISNULL(STUFF((
        SELECT TOP (10) N', ' + bt.DatabaseName
        FROM #BackupTargets AS bt
        WHERE bt.UrlDeviceCount = 0 AND bt.UncDeviceCount = 0 AND bt.TapeDeviceCount = 0
        ORDER BY bt.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'(none)');

    SET @NoHistoryList = ISNULL(STUFF((
        SELECT TOP (10) N', ' + ud.DatabaseName
        FROM #UserDatabases AS ud
        WHERE NOT EXISTS (SELECT 1 FROM #BackupTargets AS bt WHERE bt.DatabaseName = ud.DatabaseName)
        ORDER BY ud.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'(none)');

    IF @TotalDbs = 0
    BEGIN
        SET @Score   = 1;
        SET @Finding = N'MANUAL VERIFICATION REQUIRED: no online user databases were found on this instance, so backup storage redundancy could not be assessed from backup history. Re-run once user databases are present, or evidence redundancy for system database backups separately.';
    END
    ELSE IF @WithHistory = 0
    BEGIN
        SET @Score   = 0;
        SET @Finding = N'None of the ' + CAST(@TotalDbs AS NVARCHAR(20)) + N' online user database(s) have any full backup recorded in msdb in the last ' + CAST(@LookbackDays AS NVARCHAR(10)) + N' day(s), so there is no backup to store redundantly. Databases without history include: ' + @NoHistoryList + N'.';
    END
    ELSE IF @LocalOnlyDbs = 0 AND @NoHistoryDbs = 0
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'All ' + CAST(@TotalDbs AS NVARCHAR(20)) + N' online user database(s) have full backups in the last ' + CAST(@LookbackDays AS NVARCHAR(10)) + N' day(s) written to at least one off-box destination (Azure Blob URL: ' + CAST(@UrlDbs AS NVARCHAR(20)) + N' database(s), UNC/network path: ' + CAST(@UncDbs AS NVARCHAR(20)) + N', tape: ' + CAST(@TapeDbs AS NVARCHAR(20)) + N'). No database relies solely on local disk. Note: the replication tier of the target storage (LRS/ZRS/GRS/GZRS or SAN replication) is outside SQL Server and should be confirmed against the documented geo-redundancy requirement.';
    END
    ELSE IF @LocalOnlyDbs = 0
    BEGIN
        SET @Score   = 2;
        SET @Finding = N'All ' + CAST(@WithHistory AS NVARCHAR(20)) + N' user database(s) with recent full backup history write to an off-box destination (Azure Blob URL: ' + CAST(@UrlDbs AS NVARCHAR(20)) + N', UNC/network path: ' + CAST(@UncDbs AS NVARCHAR(20)) + N', tape: ' + CAST(@TapeDbs AS NVARCHAR(20)) + N'), but ' + CAST(@NoHistoryDbs AS NVARCHAR(20)) + N' of ' + CAST(@TotalDbs AS NVARCHAR(20)) + N' online user database(s) have no full backup in the last ' + CAST(@LookbackDays AS NVARCHAR(10)) + N' day(s) and therefore no redundant copy: ' + @NoHistoryList + N'.';
    END
    ELSE IF @RedundantDbs > 0
    BEGIN
        SET @Score   = 1;
        SET @Finding = CAST(@RedundantDbs AS NVARCHAR(20)) + N' of ' + CAST(@TotalDbs AS NVARCHAR(20)) + N' online user database(s) back up to an off-box destination (Azure Blob URL: ' + CAST(@UrlDbs AS NVARCHAR(20)) + N', UNC/network path: ' + CAST(@UncDbs AS NVARCHAR(20)) + N', tape: ' + CAST(@TapeDbs AS NVARCHAR(20)) + N'), but ' + CAST(@LocalOnlyDbs AS NVARCHAR(20)) + N' database(s) back up to local disk only: ' + @LocalOnlyList + N'. A further ' + CAST(@NoHistoryDbs AS NVARCHAR(20)) + N' database(s) have no full backup in the last ' + CAST(@LookbackDays AS NVARCHAR(10)) + N' day(s): ' + @NoHistoryList + N'.';
    END
    ELSE
    BEGIN
        SET @Score   = 0;
        SET @Finding = N'Every one of the ' + CAST(@WithHistory AS NVARCHAR(20)) + N' user database(s) with full backup history in the last ' + CAST(@LookbackDays AS NVARCHAR(10)) + N' day(s) writes backups to local disk only - no Azure Blob URL, UNC/network or tape destination was recorded. Local-disk-only databases include: ' + @LocalOnlyList + N'. Additionally ' + CAST(@NoHistoryDbs AS NVARCHAR(20)) + N' database(s) have no full backup history: ' + @NoHistoryList + N'. Backups are not stored redundantly and would be lost together with the host.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#BackupTargets') IS NOT NULL DROP TABLE #BackupTargets;
IF OBJECT_ID('tempdb..#UserDatabases') IS NOT NULL DROP TABLE #UserDatabases;