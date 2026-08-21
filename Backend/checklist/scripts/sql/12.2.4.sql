/*
    Checklist Item : 12.2.4 - Backup storage costs monitored (retention tuned)
    Scope          : SERVER
    Access         : READ-ONLY (msdb backup history + temp table only)
    Output         : Result, Score, DatabaseQueried, Finding
*/
SET NOCOUNT ON;

DECLARE @EngineEdition       INT           = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Result              NVARCHAR(20);
DECLARE @Score               INT;
DECLARE @DatabaseQueried     NVARCHAR(128) = N'msdb';
DECLARE @Finding             NVARCHAR(4000);
DECLARE @Sql                 NVARCHAR(MAX);

DECLARE @TotalBackups30      BIGINT;
DECLARE @CompressedBackups30 BIGINT;
DECLARE @RawSizeGB30         DECIMAL(18,2);
DECLARE @StoredSizeGB30      DECIMAL(18,2);
DECLARE @HistoryRows         BIGINT;
DECLARE @HistoryOldestDays   INT;
DECLARE @DbCount30           INT;
DECLARE @FullBackups30       BIGINT;
DECLARE @LogBackups30        BIGINT;
DECLARE @CompressionPct      DECIMAL(5,1);
DECLARE @SavingsPct          DECIMAL(5,1);
DECLARE @HistoryBounded      BIT;
DECLARE @CompressionTuned    BIT;

/* Azure SQL Database: msdb is not addressable and backup retention is platform-managed. */
IF @EngineEdition = 5
BEGIN
    SELECT
        CAST(N'NeedsReview' AS NVARCHAR(20)) AS Result,
        CAST(2 AS INT)                       AS Score,
        CAST(DB_NAME() AS NVARCHAR(128))     AS DatabaseQueried,
        CAST(N'Azure SQL Database detected (EngineEdition 5). Backup storage is platform-managed and msdb backup history is not queryable from the instance. Manually confirm that short-term retention (1-35 days), long-term retention policy and the resulting backup storage charges are reviewed in the Azure portal / Cost Management.' AS NVARCHAR(4000)) AS Finding;
    RETURN;
END

IF DB_ID('msdb') IS NULL OR HAS_DBACCESS('msdb') = 0
BEGIN
    SELECT
        CAST(N'NeedsReview' AS NVARCHAR(20)) AS Result,
        CAST(2 AS INT)                       AS Score,
        CAST(N'msdb' AS NVARCHAR(128))       AS DatabaseQueried,
        CAST(N'The msdb database is not present or the audit login has no access to it, so backup history, backup sizes and retention cleanup could not be evaluated. Re-run with an account holding at least db_datareader on msdb, or provide the backup storage / retention review evidence manually.' AS NVARCHAR(4000)) AS Finding;
    RETURN;
END

IF OBJECT_ID('tempdb..#BackupMetrics') IS NOT NULL
    DROP TABLE #BackupMetrics;

CREATE TABLE #BackupMetrics
(
    TotalBackups30      BIGINT        NULL,
    CompressedBackups30 BIGINT        NULL,
    RawSizeGB30         DECIMAL(18,2) NULL,
    StoredSizeGB30      DECIMAL(18,2) NULL,
    HistoryRows         BIGINT        NULL,
    HistoryOldestDays   INT           NULL,
    DbCount30           INT           NULL,
    FullBackups30       BIGINT        NULL,
    LogBackups30        BIGINT        NULL
);

/* Dynamic SQL keeps the cross-database msdb reference out of compile scope on unsupported editions. */
SET @Sql = N'
INSERT INTO #BackupMetrics
(
    TotalBackups30, CompressedBackups30, RawSizeGB30, StoredSizeGB30,
    HistoryRows, HistoryOldestDays, DbCount30, FullBackups30, LogBackups30
)
SELECT
    SUM(CASE WHEN bs.backup_finish_date >= DATEADD(DAY, -30, GETDATE()) THEN 1 ELSE 0 END),
    SUM(CASE WHEN bs.backup_finish_date >= DATEADD(DAY, -30, GETDATE())
                  AND ISNULL(bs.compressed_backup_size, bs.backup_size) < bs.backup_size THEN 1 ELSE 0 END),
    CAST(SUM(CASE WHEN bs.backup_finish_date >= DATEADD(DAY, -30, GETDATE())
                  THEN ISNULL(bs.backup_size, 0) ELSE 0 END) / 1073741824.0 AS DECIMAL(18,2)),
    CAST(SUM(CASE WHEN bs.backup_finish_date >= DATEADD(DAY, -30, GETDATE())
                  THEN ISNULL(bs.compressed_backup_size, ISNULL(bs.backup_size, 0)) ELSE 0 END) / 1073741824.0 AS DECIMAL(18,2)),
    COUNT_BIG(*),
    DATEDIFF(DAY, MIN(bs.backup_finish_date), GETDATE()),
    COUNT(DISTINCT CASE WHEN bs.backup_finish_date >= DATEADD(DAY, -30, GETDATE()) THEN bs.database_name END),
    SUM(CASE WHEN bs.backup_finish_date >= DATEADD(DAY, -30, GETDATE()) AND bs.type = ''D'' THEN 1 ELSE 0 END),
    SUM(CASE WHEN bs.backup_finish_date >= DATEADD(DAY, -30, GETDATE()) AND bs.type = ''L'' THEN 1 ELSE 0 END)
FROM msdb.dbo.backupset AS bs;';

BEGIN TRY
    EXEC sys.sp_executesql @Sql;
END TRY
BEGIN CATCH
    /* Leave the metrics table empty; handled as insufficient evidence below. */
    SET @Finding = NULL;
END CATCH

SELECT
    @TotalBackups30      = TotalBackups30,
    @CompressedBackups30 = CompressedBackups30,
    @RawSizeGB30         = RawSizeGB30,
    @StoredSizeGB30      = StoredSizeGB30,
    @HistoryRows         = HistoryRows,
    @HistoryOldestDays   = HistoryOldestDays,
    @DbCount30           = DbCount30,
    @FullBackups30       = FullBackups30,
    @LogBackups30        = LogBackups30
FROM #BackupMetrics;

SET @TotalBackups30      = ISNULL(@TotalBackups30, 0);
SET @CompressedBackups30 = ISNULL(@CompressedBackups30, 0);
SET @RawSizeGB30         = ISNULL(@RawSizeGB30, 0);
SET @StoredSizeGB30      = ISNULL(@StoredSizeGB30, 0);
SET @HistoryRows         = ISNULL(@HistoryRows, 0);
SET @DbCount30           = ISNULL(@DbCount30, 0);
SET @FullBackups30       = ISNULL(@FullBackups30, 0);
SET @LogBackups30        = ISNULL(@LogBackups30, 0);

SET @CompressionPct = CASE WHEN @TotalBackups30 > 0
                           THEN CAST(100.0 * @CompressedBackups30 / @TotalBackups30 AS DECIMAL(5,1))
                           ELSE CAST(0 AS DECIMAL(5,1)) END;

SET @SavingsPct     = CASE WHEN @RawSizeGB30 > 0
                           THEN CAST(100.0 * (@RawSizeGB30 - @StoredSizeGB30) / @RawSizeGB30 AS DECIMAL(5,1))
                           ELSE CAST(0 AS DECIMAL(5,1)) END;

SET @HistoryBounded   = CASE WHEN @HistoryOldestDays IS NOT NULL AND @HistoryOldestDays <= 400 THEN 1 ELSE 0 END;
SET @CompressionTuned = CASE WHEN @CompressionPct >= 90.0 THEN 1 ELSE 0 END;

IF @TotalBackups30 = 0
BEGIN
    SET @Score   = 0;
    SET @Finding = N'No backup records were found in msdb.dbo.backupset for the last 30 days (total retained history rows: '
                 + CAST(@HistoryRows AS NVARCHAR(20))
                 + N'). Backup storage consumption and retention cannot be monitored because no recent backups are being recorded on this instance.';
END
ELSE IF @HistoryBounded = 1 AND @CompressionTuned = 1
BEGIN
    SET @Score   = 3;
    SET @Finding = N'Backup retention appears tuned and storage cost controlled. Last 30 days: '
                 + CAST(@TotalBackups30 AS NVARCHAR(20)) + N' backups across '
                 + CAST(@DbCount30 AS NVARCHAR(20)) + N' database(s) ('
                 + CAST(@FullBackups30 AS NVARCHAR(20)) + N' full, '
                 + CAST(@LogBackups30 AS NVARCHAR(20)) + N' log); '
                 + CAST(@CompressionPct AS NVARCHAR(20)) + N'% compressed, storing '
                 + CAST(@StoredSizeGB30 AS NVARCHAR(30)) + N' GB instead of '
                 + CAST(@RawSizeGB30 AS NVARCHAR(30)) + N' GB ('
                 + CAST(@SavingsPct AS NVARCHAR(20)) + N'% saved). Backup history is bounded at '
                 + CAST(ISNULL(@HistoryOldestDays, 0) AS NVARCHAR(20)) + N' day(s) / '
                 + CAST(@HistoryRows AS NVARCHAR(20)) + N' rows, indicating active history cleanup.';
END
ELSE IF @HistoryBounded = 1 OR @CompressionPct >= 50.0
BEGIN
    SET @Score   = 2;
    SET @Finding = N'Backup storage management is only partially tuned. Last 30 days: '
                 + CAST(@TotalBackups30 AS NVARCHAR(20)) + N' backups across '
                 + CAST(@DbCount30 AS NVARCHAR(20)) + N' database(s); compression used on '
                 + CAST(@CompressionPct AS NVARCHAR(20)) + N'% of backups ('
                 + CAST(@StoredSizeGB30 AS NVARCHAR(30)) + N' GB stored vs '
                 + CAST(@RawSizeGB30 AS NVARCHAR(30)) + N' GB raw, '
                 + CAST(@SavingsPct AS NVARCHAR(20)) + N'% saved); oldest retained backup history row is '
                 + CAST(ISNULL(@HistoryOldestDays, 0) AS NVARCHAR(20)) + N' day(s) old over '
                 + CAST(@HistoryRows AS NVARCHAR(20)) + N' rows. Confirm manually whether backup storage cost and retention are formally reviewed.';
END
ELSE
BEGIN
    SET @Score   = 1;
    SET @Finding = N'No evidence that backup storage cost or retention is managed. Last 30 days: '
                 + CAST(@TotalBackups30 AS NVARCHAR(20)) + N' backups across '
                 + CAST(@DbCount30 AS NVARCHAR(20)) + N' database(s) with only '
                 + CAST(@CompressionPct AS NVARCHAR(20)) + N'% compressed ('
                 + CAST(@StoredSizeGB30 AS NVARCHAR(30)) + N' GB stored vs '
                 + CAST(@RawSizeGB30 AS NVARCHAR(30)) + N' GB raw); backup history is unbounded at '
                 + CAST(ISNULL(@HistoryOldestDays, 0) AS NVARCHAR(20)) + N' day(s) / '
                 + CAST(@HistoryRows AS NVARCHAR(20)) + N' rows, showing no retention cleanup.';
END

SET @Result = CASE WHEN @Score = 3 THEN N'Pass'
                   WHEN @Score = 2 THEN N'NeedsReview'
                   ELSE N'Fail' END;

IF OBJECT_ID('tempdb..#BackupMetrics') IS NOT NULL
    DROP TABLE #BackupMetrics;

SELECT
    CAST(@Result AS NVARCHAR(20))            AS Result,
    CAST(@Score AS INT)                      AS Score,
    CAST(@DatabaseQueried AS NVARCHAR(128))  AS DatabaseQueried,
    CAST(@Finding AS NVARCHAR(4000))         AS Finding;