-- Checklist: Backup storage costs monitored (retention tuned)
-- Scope: SERVER
-- Scoring: 3 = history cleanup bounded and 90 percent or more of backups compressed; 2 = one of the two controls in place (or Azure platform-managed backups); 1 = backups exist with neither control; 0 = no backup activity recorded in the last 30 days

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Backup history evidence could not be read';
DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Backups30 INT = 0;
DECLARE @Compressed30 INT = 0;
DECLARE @RawGB DECIMAL(19,2) = 0;
DECLARE @StoredGB DECIMAL(19,2) = 0;
DECLARE @HistoryRows BIGINT = 0;
DECLARE @OldestDays INT = 0;
DECLARE @Databases INT = 0;
DECLARE @CompPct DECIMAL(9,1) = 0;
DECLARE @Bounded INT = 0;
DECLARE @Compressed INT = 0;
DECLARE @Readable BIT = 0;
DECLARE @Sql NVARCHAR(MAX);

IF @Edition = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database: backup storage and retention are managed by the platform and msdb backup history is not exposed to the instance, so retention cost tuning cannot be measured here';
END
ELSE
BEGIN
    SET @Sql = N'SELECT @b = ISNULL(SUM(CASE WHEN bs.backup_finish_date >= DATEADD(DAY, -30, GETDATE()) THEN 1 ELSE 0 END), 0),
       @c = ISNULL(SUM(CASE WHEN bs.backup_finish_date >= DATEADD(DAY, -30, GETDATE())
                             AND ISNULL(bs.compressed_backup_size, bs.backup_size) < bs.backup_size THEN 1 ELSE 0 END), 0),
       @r = ISNULL(CONVERT(DECIMAL(19,2), SUM(CASE WHEN bs.backup_finish_date >= DATEADD(DAY, -30, GETDATE())
                             THEN CONVERT(DECIMAL(19,2), ISNULL(bs.backup_size, 0)) ELSE 0 END) / 1073741824.0), 0),
       @s = ISNULL(CONVERT(DECIMAL(19,2), SUM(CASE WHEN bs.backup_finish_date >= DATEADD(DAY, -30, GETDATE())
                             THEN CONVERT(DECIMAL(19,2), ISNULL(bs.compressed_backup_size, ISNULL(bs.backup_size, 0))) ELSE 0 END) / 1073741824.0), 0),
       @d = ISNULL(COUNT(DISTINCT CASE WHEN bs.backup_finish_date >= DATEADD(DAY, -30, GETDATE()) THEN bs.database_name END), 0),
       @h = COUNT_BIG(*),
       @o = ISNULL(DATEDIFF(DAY, MIN(bs.backup_finish_date), GETDATE()), 0)
FROM msdb.dbo.backupset AS bs;';

    BEGIN TRY
        EXEC sys.sp_executesql @Sql,
             N'@b INT OUTPUT, @c INT OUTPUT, @r DECIMAL(19,2) OUTPUT, @s DECIMAL(19,2) OUTPUT, @d INT OUTPUT, @h BIGINT OUTPUT, @o INT OUTPUT',
             @b = @Backups30 OUTPUT, @c = @Compressed30 OUTPUT, @r = @RawGB OUTPUT, @s = @StoredGB OUTPUT,
             @d = @Databases OUTPUT, @h = @HistoryRows OUTPUT, @o = @OldestDays OUTPUT;
        SET @Readable = 1;
    END TRY
    BEGIN CATCH
        SET @Readable = 0;
    END CATCH;

    SET @CompPct = ISNULL(CONVERT(DECIMAL(9,1), 100.0 * @Compressed30 / NULLIF(@Backups30, 0)), 0);
    SET @Bounded = CASE WHEN @OldestDays BETWEEN 1 AND 400 THEN 1 ELSE 0 END;
    SET @Compressed = CASE WHEN @CompPct >= 90.0 THEN 1 ELSE 0 END;

    IF @Readable = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = 'msdb.dbo.backupset is not readable by the audit login, so backup volume, compression and retention cleanup could not be measured';
    END
    ELSE IF @Backups30 = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = CONCAT('No backups recorded in msdb.dbo.backupset in the last 30 days (', @HistoryRows,
                              ' history row(s) retained overall); backup storage consumption is not being produced or tracked');
    END
    ELSE
    BEGIN
        SET @Score = CASE WHEN @Bounded + @Compressed = 2 THEN 3 WHEN @Bounded + @Compressed = 1 THEN 2 ELSE 1 END;
        SET @Finding = CONCAT(@Backups30, ' backup(s) across ', @Databases, ' database(s) in 30 days storing ',
                              @StoredGB, ' GB of ', @RawGB, ' GB raw; ', @CompPct,
                              ' percent compressed; backup history holds ', @HistoryRows, ' row(s) with the oldest at ',
                              @OldestDays, ' day(s), so history cleanup is ',
                              CASE WHEN @Bounded = 1 THEN 'bounded' ELSE 'not running' END);
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
