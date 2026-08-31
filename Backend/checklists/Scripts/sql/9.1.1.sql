SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Result NVARCHAR(50);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @Detail NVARCHAR(MAX);

IF OBJECT_ID('tempdb..#BackupState') IS NOT NULL
    DROP TABLE #BackupState;

CREATE TABLE #BackupState
(
    DatabaseName  SYSNAME       NOT NULL,
    RecoveryModel NVARCHAR(60)  NULL,
    LastFull      DATETIME      NULL,
    LastDiff      DATETIME      NULL,
    LastLog       DATETIME      NULL,
    FullAgeHours  INT           NULL,
    LogAgeHours   INT           NULL
);

IF @EngineEdition <> 5
BEGIN
    INSERT INTO #BackupState (DatabaseName, RecoveryModel, LastFull, LastDiff, LastLog, FullAgeHours, LogAgeHours)
    SELECT d.name,
           d.recovery_model_desc,
           b.LastFull,
           b.LastDiff,
           b.LastLog,
           DATEDIFF(HOUR, b.LastFull, GETDATE()),
           DATEDIFF(HOUR, b.LastLog, GETDATE())
    FROM sys.databases AS d
    OUTER APPLY
    (
        SELECT MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END) AS LastFull,
               MAX(CASE WHEN bs.type = 'I' THEN bs.backup_finish_date END) AS LastDiff,
               MAX(CASE WHEN bs.type = 'L' THEN bs.backup_finish_date END) AS LastLog
        FROM msdb.dbo.backupset AS bs
        WHERE bs.database_name = d.name
    ) AS b
    WHERE d.database_id <> 2
      AND d.state_desc = 'ONLINE'
      AND d.is_read_only = 0
      AND d.source_database_id IS NULL;
END

DECLARE @Total INT = 0, @NoFull INT = 0, @StaleFull INT = 0, @LogEligible INT = 0, @LogGap INT = 0;

SELECT @Total       = COUNT(*),
       @NoFull      = SUM(CASE WHEN LastFull IS NULL THEN 1 ELSE 0 END),
       @StaleFull   = SUM(CASE WHEN LastFull IS NOT NULL AND FullAgeHours > 168 THEN 1 ELSE 0 END),
       @LogEligible = SUM(CASE WHEN RecoveryModel IN ('FULL', 'BULK_LOGGED') THEN 1 ELSE 0 END),
       @LogGap      = SUM(CASE WHEN RecoveryModel IN ('FULL', 'BULK_LOGGED')
                                AND (LastLog IS NULL OR LogAgeHours > 24) THEN 1 ELSE 0 END)
FROM #BackupState;

SELECT @DatabaseQueried = STUFF((SELECT N', ' + DatabaseName
                                 FROM #BackupState
                                 ORDER BY DatabaseName
                                 FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

SELECT @Detail = STUFF((SELECT N'; ' + DatabaseName
                             + N' [' + ISNULL(RecoveryModel, N'UNKNOWN') + N']'
                             + N' last full=' + ISNULL(CONVERT(NVARCHAR(19), LastFull, 120), N'NONE')
                             + N', last diff=' + ISNULL(CONVERT(NVARCHAR(19), LastDiff, 120), N'NONE')
                             + N', last log=' + ISNULL(CONVERT(NVARCHAR(19), LastLog, 120), N'NONE')
                        FROM #BackupState
                        WHERE LastFull IS NULL
                           OR FullAgeHours > 168
                           OR (RecoveryModel IN ('FULL', 'BULK_LOGGED') AND (LastLog IS NULL OR LogAgeHours > 24))
                        ORDER BY DatabaseName
                        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

IF @EngineEdition = 5
BEGIN
    SET @Score = 2;
    SET @DatabaseQueried = DB_NAME();
    SET @Finding = N'Azure SQL Database (EngineEdition 5) detected: backups are automated by the platform (full, differential and 5-10 minute log backups) and msdb.dbo.backupset is not exposed, so cadence cannot be read from the instance. Confirm that the configured point-in-time-restore retention and any long-term retention policy meet the documented RPO for database ' + ISNULL(DB_NAME(), N'(unknown)') + N'.';
END
ELSE IF @Total = 0
BEGIN
    SET @Score = 1;
    SET @DatabaseQueried = N'(no eligible databases)';
    SET @Finding = N'No online, writable, non-tempdb databases were found on this instance, so no backup strategy could be evaluated. Re-run the check once user databases are online.';
END
ELSE IF @NoFull = @Total
BEGIN
    SET @Score = 0;
    SET @Finding = N'No full backup history exists in msdb.dbo.backupset for any of the ' + CAST(@Total AS NVARCHAR(10))
                 + N' evaluated database(s). There is no evidence of any backup strategy, so no RPO can be met. Databases: ' + ISNULL(@Detail, N'(none)') + N'.';
END
ELSE IF @NoFull > 0 OR @StaleFull > 0
BEGIN
    SET @Score = 1;
    SET @Finding = CAST(@NoFull AS NVARCHAR(10)) + N' of ' + CAST(@Total AS NVARCHAR(10))
                 + N' evaluated database(s) have no full backup and ' + CAST(@StaleFull AS NVARCHAR(10))
                 + N' have a full backup older than 7 days; ' + CAST(@LogGap AS NVARCHAR(10)) + N' of '
                 + CAST(@LogEligible AS NVARCHAR(10)) + N' FULL/BULK_LOGGED database(s) have a missing or >24h old log backup. Affected: '
                 + ISNULL(@Detail, N'(none)') + N'.';
END
ELSE IF @LogGap > 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'Full backups are current (within 7 days) for all ' + CAST(@Total AS NVARCHAR(10))
                 + N' evaluated database(s), but ' + CAST(@LogGap AS NVARCHAR(10)) + N' of '
                 + CAST(@LogEligible AS NVARCHAR(10)) + N' database(s) in FULL/BULK_LOGGED recovery have no transaction log backup or one older than 24 hours, which caps the achievable RPO at the full/differential interval. Affected: '
                 + ISNULL(@Detail, N'(none)') + N'.';
END
ELSE
BEGIN
    SET @Score = 3;
    SET @Finding = N'All ' + CAST(@Total AS NVARCHAR(10))
                 + N' evaluated database(s) have a full backup within the last 7 days, and all '
                 + CAST(@LogEligible AS NVARCHAR(10))
                 + N' database(s) in FULL/BULK_LOGGED recovery have a transaction log backup within the last 24 hours, evidencing an active full/differential/log backup strategy. Compare the observed log backup interval against the documented RPO target to confirm alignment.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result,
       @Score AS Score,
       ISNULL(@DatabaseQueried, N'(none)') AS DatabaseQueried,
       @Finding AS Finding;