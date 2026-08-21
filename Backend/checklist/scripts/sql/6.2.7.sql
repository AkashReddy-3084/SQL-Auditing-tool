/*
    Checklist Item : 6.2.7 - Backups are encrypted
    Scope          : SERVER
    Type           : Read-only audit script (SELECT / metadata reads only)
    Data source    : msdb.dbo.backupset backup history (last 90 days)
    Output         : Result, Score, DatabaseQueried, Finding
*/
SET NOCOUNT ON;

DECLARE @Result           NVARCHAR(50);
DECLARE @Score            INT            = 0;
DECLARE @DatabaseQueried  NVARCHAR(128)  = N'msdb';
DECLARE @Finding          NVARCHAR(4000) = N'';
DECLARE @EngineEdition    INT            = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @RetentionDays    INT            = 90;

IF @EngineEdition = 5
BEGIN
    /* Azure SQL Database: msdb backup history is not exposed; backups are service-managed and encrypted at rest. */
    SET @DatabaseQueried = DB_NAME();
    SET @Score   = 3;
    SET @Finding = N'Azure SQL Database (EngineEdition 5) detected. Automated backups are managed and encrypted at rest by the platform; msdb.dbo.backupset backup history is not available for verification on this engine.';
END
ELSE
BEGIN
    DECLARE @HasEncryptionMetadata BIT =
        CASE WHEN COL_LENGTH('msdb.dbo.backupset', 'key_algorithm') IS NOT NULL THEN 1 ELSE 0 END;

    IF OBJECT_ID('tempdb..#BackupEncryption') IS NOT NULL
        DROP TABLE #BackupEncryption;

    CREATE TABLE #BackupEncryption
    (
        DatabaseName      NVARCHAR(256) NOT NULL,
        TotalBackups      INT           NOT NULL,
        EncryptedBackups  INT           NOT NULL
    );

    IF @HasEncryptionMetadata = 1
    BEGIN
        DECLARE @sql NVARCHAR(MAX) = N'
            SELECT ISNULL(bs.database_name, N''(unknown)'') AS DatabaseName,
                   COUNT_BIG(*) AS TotalBackups,
                   SUM(CASE WHEN bs.key_algorithm IS NOT NULL THEN 1 ELSE 0 END) AS EncryptedBackups
            FROM msdb.dbo.backupset AS bs
            WHERE bs.type IN (''D'', ''I'', ''L'')
              AND bs.backup_finish_date IS NOT NULL
              AND bs.backup_finish_date >= DATEADD(DAY, -@Days, SYSDATETIME())
            GROUP BY ISNULL(bs.database_name, N''(unknown)'');';

        INSERT INTO #BackupEncryption (DatabaseName, TotalBackups, EncryptedBackups)
        EXEC sp_executesql @sql, N'@Days INT', @Days = @RetentionDays;
    END

    DECLARE @TotalBackups      INT = 0;
    DECLARE @EncryptedBackups  INT = 0;
    DECLARE @DatabaseCount     INT = 0;
    DECLARE @FullyEncryptedDbs INT = 0;
    DECLARE @PercentEncrypted  DECIMAL(5,1) = 0.0;
    DECLARE @OffenderList      NVARCHAR(2000) = NULL;

    SELECT @TotalBackups     = ISNULL(SUM(be.TotalBackups), 0),
           @EncryptedBackups = ISNULL(SUM(be.EncryptedBackups), 0),
           @DatabaseCount    = COUNT(*)
    FROM #BackupEncryption AS be;

    SELECT @FullyEncryptedDbs = COUNT(*)
    FROM #BackupEncryption AS be
    WHERE be.EncryptedBackups = be.TotalBackups;

    SELECT @OffenderList = STUFF((
        SELECT TOP (10) N', ' + x.DatabaseName
                      + N' (' + CAST(x.TotalBackups - x.EncryptedBackups AS NVARCHAR(20))
                      + N' of ' + CAST(x.TotalBackups AS NVARCHAR(20)) + N' unencrypted)'
        FROM #BackupEncryption AS x
        WHERE x.EncryptedBackups < x.TotalBackups
        ORDER BY (x.TotalBackups - x.EncryptedBackups) DESC, x.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

    IF @TotalBackups > 0
        SET @PercentEncrypted = CAST(100.0 * @EncryptedBackups / @TotalBackups AS DECIMAL(5,1));

    IF @HasEncryptionMetadata = 0
    BEGIN
        SET @Score   = 0;
        SET @Finding = N'This SQL Server version does not expose backup encryption metadata (msdb.dbo.backupset.key_algorithm is absent; native backup encryption was introduced in SQL Server 2014). Backup encryption cannot be confirmed on instance '
                     + ISNULL(CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128)), N'(unknown)')
                     + N' running version ' + ISNULL(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(64)), N'(unknown)') + N'.';
    END
    ELSE IF @TotalBackups = 0
    BEGIN
        SET @Score   = 0;
        SET @Finding = N'No data, differential or log backup records were found in msdb.dbo.backupset for the last '
                     + CAST(@RetentionDays AS NVARCHAR(10))
                     + N' days, so backup encryption could not be confirmed. Backup history may have been purged, or backups may be taken by an external/third-party tool that does not log to msdb.';
    END
    ELSE IF @EncryptedBackups = @TotalBackups
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'All ' + CAST(@TotalBackups AS NVARCHAR(20))
                     + N' backup(s) recorded in msdb.dbo.backupset over the last ' + CAST(@RetentionDays AS NVARCHAR(10))
                     + N' days across ' + CAST(@DatabaseCount AS NVARCHAR(20))
                     + N' database(s) are encrypted (key_algorithm is populated on every backupset row).';
    END
    ELSE
    BEGIN
        SET @Score = CASE WHEN @EncryptedBackups = 0 THEN 0 ELSE 1 END;
        SET @Finding = CAST(@EncryptedBackups AS NVARCHAR(20)) + N' of ' + CAST(@TotalBackups AS NVARCHAR(20))
                     + N' backup(s) (' + CAST(@PercentEncrypted AS NVARCHAR(10))
                     + N'%) taken in the last ' + CAST(@RetentionDays AS NVARCHAR(10)) + N' days are encrypted. '
                     + CAST(@DatabaseCount - @FullyEncryptedDbs AS NVARCHAR(20)) + N' of '
                     + CAST(@DatabaseCount AS NVARCHAR(20)) + N' database(s) have at least one unencrypted backup. '
                     + N'Databases with unencrypted backups (top 10): ' + ISNULL(@OffenderList, N'none') + N'.';
    END

    IF OBJECT_ID('tempdb..#BackupEncryption') IS NOT NULL
        DROP TABLE #BackupEncryption;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;