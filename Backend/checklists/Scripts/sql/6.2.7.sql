-- Checklist: Backups are encrypted
-- Scope: SERVER
-- Scoring: 3 = Azure SQL Database platform encryption, or every backup recorded in the last 30 days is encrypted; 2 = at least 90% of them are encrypted; 1 = some but under 90% are encrypted; 0 = none are encrypted, no recent history exists, or the history could not be read

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Backup encryption evidence was not readable';
DECLARE @Engine INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Total INT = -1;
DECLARE @Enc INT = 0;
DECLARE @Algorithm NVARCHAR(200) = 'none';
DECLARE @Encryptor NVARCHAR(200) = 'none';
DECLARE @MediaSets INT = 0;
DECLARE @Probe NVARCHAR(1200);
DECLARE @Ratio DECIMAL(9, 4) = 0;

IF @Engine <> 5
BEGIN
    BEGIN TRY
        SET @Probe = N'SELECT @t = COUNT(*),
       @e = ISNULL(SUM(CASE WHEN bs.key_algorithm IS NOT NULL THEN 1 ELSE 0 END), 0),
       @a = ISNULL(MAX(CONVERT(NVARCHAR(200), bs.key_algorithm)), N''none''),
       @x = ISNULL(MAX(CONVERT(NVARCHAR(200), bs.encryptor_type)), N''none''),
       @m = ISNULL(COUNT(DISTINCT bs.media_set_id), 0)
FROM msdb.dbo.backupset AS bs
JOIN msdb.dbo.backupmediaset AS bms ON bms.media_set_id = bs.media_set_id
WHERE bs.backup_start_date >= DATEADD(day, -30, GETDATE());';
        EXEC sys.sp_executesql @Probe,
             N'@t INT OUTPUT, @e INT OUTPUT, @a NVARCHAR(200) OUTPUT, @x NVARCHAR(200) OUTPUT, @m INT OUTPUT',
             @t = @Total OUTPUT, @e = @Enc OUTPUT, @a = @Algorithm OUTPUT,
             @x = @Encryptor OUTPUT, @m = @MediaSets OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Total = -1;
    END CATCH
END

SET @Ratio = CASE WHEN @Total <= 0 THEN 0
                  ELSE CONVERT(DECIMAL(9, 4), @Enc) / NULLIF(@Total, 0) END;

SET @Score = CASE
    WHEN @Engine = 5 THEN 3
    WHEN @Total <= 0 THEN 0
    WHEN @Enc = @Total THEN 3
    WHEN ISNULL(@Ratio, 0) >= 0.90 THEN 2
    WHEN @Enc > 0 THEN 1
    ELSE 0 END;

SET @Finding = CASE
    WHEN @Engine = 5 THEN 'Azure SQL Database: automated backups are encrypted by the platform and no user-managed backup history is exposed to T-SQL'
    WHEN @Total = -1 THEN 'Backup history in msdb could not be read with the current permissions'
    WHEN @Total = 0 THEN 'No backup history rows recorded in the last 30 days'
    ELSE CONCAT('backup history rows in the last 30 days = ', @Total,
                ', encrypted rows = ', @Enc,
                ', media sets covered = ', @MediaSets,
                ', key algorithm observed = ', @Algorithm,
                ', encryptor type observed = ', @Encryptor)
    END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
