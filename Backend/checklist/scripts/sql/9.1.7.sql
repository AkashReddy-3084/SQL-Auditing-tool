SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Result NVARCHAR(20);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(256);
DECLARE @Finding NVARCHAR(MAX);

IF @EngineEdition = 5
BEGIN
    SET @Score = 3;
    SET @DatabaseQueried = DB_NAME();
    SET @Finding = N'Azure SQL Database detected (EngineEdition = 5). The recovery model is fixed at FULL and managed by the platform; automated full, differential and transaction log backups with point-in-time restore are always enabled and cannot be reconfigured. The recovery model is therefore appropriate by design for database [' + ISNULL(DB_NAME(), N'unknown') + N'].';

    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

    SELECT
        @Result AS Result,
        @Score AS Score,
        @DatabaseQueried AS DatabaseQueried,
        @Finding AS Finding;
END
ELSE
BEGIN
    IF OBJECT_ID('tempdb..#RecoveryModelAudit') IS NOT NULL
        DROP TABLE #RecoveryModelAudit;

    CREATE TABLE #RecoveryModelAudit
    (
        DatabaseName  SYSNAME       NOT NULL,
        RecoveryModel NVARCHAR(60)  NOT NULL,
        LastLogBackup DATETIME      NULL
    );

    INSERT INTO #RecoveryModelAudit (DatabaseName, RecoveryModel, LastLogBackup)
    SELECT
        d.name,
        d.recovery_model_desc,
        lb.LastLogBackup
    FROM sys.databases AS d
    OUTER APPLY
    (
        SELECT MAX(b.backup_finish_date) AS LastLogBackup
        FROM msdb.dbo.backupset AS b
        WHERE b.type = 'L'
          AND b.is_copy_only = 0
          AND b.database_name = d.name
    ) AS lb
    WHERE d.database_id > 4
      AND d.name NOT IN (N'master', N'model', N'msdb', N'tempdb')
      AND d.source_database_id IS NULL
      AND d.state_desc = 'ONLINE'
      AND d.is_read_only = 0;

    DECLARE @Total INT, @SimpleCount INT, @FullOrBulkCount INT, @UnsupportedCount INT;

    SELECT @Total = COUNT(*) FROM #RecoveryModelAudit;

    SELECT @SimpleCount = COUNT(*)
    FROM #RecoveryModelAudit
    WHERE RecoveryModel = N'SIMPLE';

    SELECT @FullOrBulkCount = COUNT(*)
    FROM #RecoveryModelAudit
    WHERE RecoveryModel IN (N'FULL', N'BULK_LOGGED');

    SELECT @UnsupportedCount = COUNT(*)
    FROM #RecoveryModelAudit
    WHERE RecoveryModel IN (N'FULL', N'BULK_LOGGED')
      AND (LastLogBackup IS NULL OR LastLogBackup < DATEADD(DAY, -7, GETDATE()));

    DECLARE @SimpleList NVARCHAR(MAX) =
        STUFF((
            SELECT N', ' + r.DatabaseName
            FROM #RecoveryModelAudit AS r
            WHERE r.RecoveryModel = N'SIMPLE'
            ORDER BY r.DatabaseName
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

    DECLARE @UnsupportedList NVARCHAR(MAX) =
        STUFF((
            SELECT N', ' + r.DatabaseName + N' (' + r.RecoveryModel + N', last log backup: '
                 + ISNULL(CONVERT(NVARCHAR(19), r.LastLogBackup, 120), N'never') + N')'
            FROM #RecoveryModelAudit AS r
            WHERE r.RecoveryModel IN (N'FULL', N'BULK_LOGGED')
              AND (r.LastLogBackup IS NULL OR r.LastLogBackup < DATEADD(DAY, -7, GETDATE()))
            ORDER BY r.DatabaseName
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

    DECLARE @HealthyList NVARCHAR(MAX) =
        STUFF((
            SELECT N', ' + r.DatabaseName + N' (' + r.RecoveryModel + N')'
            FROM #RecoveryModelAudit AS r
            WHERE r.RecoveryModel IN (N'FULL', N'BULK_LOGGED')
              AND r.LastLogBackup IS NOT NULL
              AND r.LastLogBackup >= DATEADD(DAY, -7, GETDATE())
            ORDER BY r.DatabaseName
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

    SET @DatabaseQueried = N'ALL DATABASES (' + CAST(@Total AS NVARCHAR(10))
        + N' online writable user database(s) on instance '
        + ISNULL(CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128)), N'unknown') + N')';

    IF @Total = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = N'No ONLINE, writable, non-snapshot user databases exist on instance '
            + ISNULL(CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128)), N'unknown')
            + N'. Only system databases are present, so no user-database recovery model configuration is applicable.';
    END
    ELSE IF @UnsupportedCount = 0 AND @SimpleCount = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = N'All ' + CAST(@Total AS NVARCHAR(10))
            + N' user database(s) run in FULL or BULK_LOGGED recovery and every one has a non-copy-only transaction log backup within the last 7 days: '
            + ISNULL(@HealthyList, N'(none listed)')
            + N'. The recovery models are appropriate and are actively supported by log backups, so point-in-time recovery is achievable and the transaction log can be truncated.';
    END
    ELSE IF @UnsupportedCount = 0 AND @SimpleCount > 0
    BEGIN
        SET @Score = 2;
        SET @Finding = N'Every FULL/BULK_LOGGED database is properly supported by recent transaction log backups ('
            + CAST(@FullOrBulkCount AS NVARCHAR(10)) + N' of ' + CAST(@Total AS NVARCHAR(10))
            + N'), but ' + CAST(@SimpleCount AS NVARCHAR(10))
            + N' user database(s) run in SIMPLE recovery and therefore have no point-in-time recovery capability: '
            + ISNULL(@SimpleList, N'(none listed)')
            + N'. Confirm SIMPLE recovery is a deliberate choice justified by the recovery point objective for each of these databases.';
    END
    ELSE IF @FullOrBulkCount > 0 AND @UnsupportedCount = @FullOrBulkCount
    BEGIN
        SET @Score = 0;
        SET @Finding = N'All ' + CAST(@FullOrBulkCount AS NVARCHAR(10))
            + N' FULL/BULK_LOGGED user database(s) declare a recovery model that is not supported by transaction log backups (no non-copy-only log backup in the last 7 days): '
            + ISNULL(@UnsupportedList, N'(none listed)')
            + N'. Additionally ' + CAST(@SimpleCount AS NVARCHAR(10))
            + N' database(s) run in SIMPLE recovery'
            + CASE WHEN @SimpleCount > 0 THEN N': ' + ISNULL(@SimpleList, N'') ELSE N'' END
            + N'. The declared recovery models are systematically inappropriate for the backup regime in place.';
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Finding = CAST(@UnsupportedCount AS NVARCHAR(10)) + N' of '
            + CAST(@FullOrBulkCount AS NVARCHAR(10))
            + N' FULL/BULK_LOGGED user database(s) have no non-copy-only transaction log backup in the last 7 days, so the declared recovery model is inappropriate for how they are actually backed up: '
            + ISNULL(@UnsupportedList, N'(none listed)')
            + N'. Databases in SIMPLE recovery: ' + CAST(@SimpleCount AS NVARCHAR(10))
            + CASE WHEN @SimpleCount > 0 THEN N' (' + ISNULL(@SimpleList, N'') + N')' ELSE N'' END
            + N'.';
    END

    DROP TABLE #RecoveryModelAudit;

    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

    SELECT
        @Result AS Result,
        @Score AS Score,
        @DatabaseQueried AS DatabaseQueried,
        @Finding AS Finding;
END