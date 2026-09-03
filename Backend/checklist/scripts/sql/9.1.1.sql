-- Checklist: Backup strategy defined and matches RPO (full/differential/log or PaaS automated)
-- Scope: SERVER
-- Scoring: 3 = platform-automated backups are in force, or every eligible database has a full backup in the last 30 days and every FULL/BULK_LOGGED database has a log backup; 2 = at least 80% have a recent full backup, or no eligible user database exists; 1 = some backup history exists but under 80% coverage; 0 = no backup history in the last 30 days

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No backup history evidence could be read';
DECLARE @Engine INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Total INT = 0;
DECLARE @WithFull INT = 0;
DECLARE @WithDiff INT = 0;
DECLARE @LogEligible INT = 0;
DECLARE @WithLog INT = 0;
DECLARE @NewestFull DATETIME = NULL;
DECLARE @NewestLog DATETIME = NULL;
DECLARE @Missing NVARCHAR(MAX) = '';
DECLARE @Err BIT = 0;
DECLARE @Sql NVARCHAR(MAX);

IF @Engine <> 5
BEGIN
    BEGIN TRY
        SET @Sql = N'
SELECT @t = COUNT(*),
       @f = ISNULL(SUM(CASE WHEN b.LastFull IS NOT NULL THEN 1 ELSE 0 END), 0),
       @i = ISNULL(SUM(CASE WHEN b.LastDiff IS NOT NULL THEN 1 ELSE 0 END), 0),
       @le = ISNULL(SUM(CASE WHEN d.recovery_model_desc IN (''FULL'', ''BULK_LOGGED'') THEN 1 ELSE 0 END), 0),
       @lg = ISNULL(SUM(CASE WHEN d.recovery_model_desc IN (''FULL'', ''BULK_LOGGED'')
                              AND b.LastLog IS NOT NULL THEN 1 ELSE 0 END), 0),
       @nf = MAX(b.LastFull),
       @nl = MAX(b.LastLog),
       @m = ISNULL(LEFT(STRING_AGG(CASE WHEN b.LastFull IS NULL
                                        THEN CONVERT(NVARCHAR(MAX), d.name + '' ['' + d.recovery_model_desc + '']'')
                                   END, '', ''), 400), '''')
FROM sys.databases AS d
OUTER APPLY (
    SELECT MAX(CASE WHEN bs.type = ''D'' THEN bs.backup_finish_date END) AS LastFull,
           MAX(CASE WHEN bs.type = ''I'' THEN bs.backup_finish_date END) AS LastDiff,
           MAX(CASE WHEN bs.type = ''L'' THEN bs.backup_finish_date END) AS LastLog
    FROM msdb.dbo.backupset AS bs
    WHERE bs.database_name = d.name
      AND bs.backup_finish_date >= DATEADD(DAY, -30, GETDATE())) AS b
WHERE d.database_id > 4 AND d.state = 0 AND d.source_database_id IS NULL AND d.is_read_only = 0;';

        EXEC sys.sp_executesql @Sql,
             N'@t INT OUTPUT, @f INT OUTPUT, @i INT OUTPUT, @le INT OUTPUT, @lg INT OUTPUT, @nf DATETIME OUTPUT, @nl DATETIME OUTPUT, @m NVARCHAR(MAX) OUTPUT',
             @t = @Total OUTPUT, @f = @WithFull OUTPUT, @i = @WithDiff OUTPUT,
             @le = @LogEligible OUTPUT, @lg = @WithLog OUTPUT,
             @nf = @NewestFull OUTPUT, @nl = @NewestLog OUTPUT, @m = @Missing OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Err = 1;
    END CATCH
END

IF @Engine = 5
BEGIN
    SET @Score = 3;
    SET @Finding = 'Azure SQL Database: platform-automated backups are in force - weekly full, differential and 5-10 minute transaction log backups are taken and retained by the service for point-in-time restore, so an explicit full/differential/log schedule is not required on this platform';
END
ELSE
BEGIN
    SET @Score = CASE
        WHEN @Err = 1 AND @Total = 0 THEN 0
        WHEN @Total = 0 THEN 2
        WHEN @WithFull = @Total AND @WithLog = @LogEligible THEN 3
        WHEN CONVERT(DECIMAL(9, 4), @WithFull) / NULLIF(@Total, 0) >= 0.80 THEN 2
        WHEN @WithFull > 0 THEN 1
        ELSE 0 END;
    SET @Finding = CASE
        WHEN @Total = 0 THEN 'No online, writable user database was found on this instance, so there is no backup gap to report'
        ELSE CONCAT('Eligible user databases = ', @Total,
            '; with a full backup in the last 30 days = ', @WithFull,
            '; with a differential = ', @WithDiff,
            '; in FULL/BULK_LOGGED recovery = ', @LogEligible,
            ', of which with a transaction log backup = ', @WithLog,
            '; newest full backup = ', ISNULL(CONVERT(NVARCHAR(19), @NewestFull, 120), 'none'),
            '; newest log backup = ', ISNULL(CONVERT(NVARCHAR(19), @NewestLog, 120), 'none'),
            CASE WHEN LEN(@Missing) > 0 THEN '. No full backup for: ' + @Missing ELSE '' END,
            CASE WHEN @Err = 1 THEN '. Backup history was not readable on this platform' ELSE '' END)
        END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;