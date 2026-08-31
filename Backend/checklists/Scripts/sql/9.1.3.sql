/*
    Checklist Item : 9.1.3 - Backups restore-tested regularly (not just taken)
    Scope          : SERVER
    Purpose        : Determine whether backups have been proven recoverable by looking for
                     actual RESTORE or RESTORE VERIFYONLY activity in msdb history, and
                     whether that activity covers the user databases that are being backed up.
    Read-only      : Yes. Only SELECT statements against msdb history and sys.databases.
*/

SET NOCOUNT ON;

DECLARE @EngineEdition   INT            = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Result          NVARCHAR(50)   = N'Fail';
DECLARE @Score           INT            = 0;
DECLARE @DatabaseQueried NVARCHAR(256)  = N'msdb';
DECLARE @Finding         NVARCHAR(4000) = N'';

IF @EngineEdition = 5
BEGIN
    SET @Score = 0;
    SET @DatabaseQueried = CAST(DB_NAME() AS NVARCHAR(256));
    SET @Finding = N'Azure SQL Database does not expose msdb backup/restore history. Restore-test evidence '
                 + N'for automated backups cannot be verified from this instance and must be demonstrated '
                 + N'through documented point-in-time restore drills recorded outside SQL Server.';
END
ELSE
BEGIN
    DECLARE @TotalRestoreEvents   INT      = 0;
    DECLARE @RestoreEvents90      INT      = 0;
    DECLARE @RestoreEvents365     INT      = 0;
    DECLARE @VerifyOnlyEvents90   INT      = 0;
    DECLARE @LastRestoreDate      DATETIME = NULL;
    DECLARE @DaysSinceLastRestore INT      = NULL;
    DECLARE @DbsWithBackups       INT      = 0;
    DECLARE @DbsTested90          INT      = 0;
    DECLARE @TestedList           NVARCHAR(2000) = NULL;
    DECLARE @UntestedList         NVARCHAR(2000) = NULL;

    /* User databases (excluding system databases) that have a full backup in the last 365 days. */
    DECLARE @BackedUpDbs TABLE (database_name NVARCHAR(256) NOT NULL PRIMARY KEY);

    INSERT INTO @BackedUpDbs (database_name)
    SELECT DISTINCT bs.database_name
    FROM msdb.dbo.backupset AS bs
    INNER JOIN sys.databases AS d
        ON d.name = bs.database_name
    WHERE bs.type = 'D'
      AND bs.backup_finish_date >= DATEADD(DAY, -365, GETDATE())
      AND d.database_id > 4
      AND d.source_database_id IS NULL;

    SELECT @DbsWithBackups = COUNT(*) FROM @BackedUpDbs;

    /* Source databases proven by a restore or VERIFYONLY event in the last 90 days. */
    DECLARE @TestedDbs TABLE (database_name NVARCHAR(256) NOT NULL PRIMARY KEY);

    INSERT INTO @TestedDbs (database_name)
    SELECT DISTINCT bs.database_name
    FROM msdb.dbo.restorehistory AS rh
    INNER JOIN msdb.dbo.backupset AS bs
        ON bs.backup_set_id = rh.backup_set_id
    WHERE rh.restore_date >= DATEADD(DAY, -90, GETDATE())
      AND bs.database_name IS NOT NULL;

    SELECT @TotalRestoreEvents = COUNT(*)
    FROM msdb.dbo.restorehistory;

    SELECT @RestoreEvents90 = COUNT(*)
    FROM msdb.dbo.restorehistory
    WHERE restore_date >= DATEADD(DAY, -90, GETDATE());

    SELECT @RestoreEvents365 = COUNT(*)
    FROM msdb.dbo.restorehistory
    WHERE restore_date >= DATEADD(DAY, -365, GETDATE());

    SELECT @VerifyOnlyEvents90 = COUNT(*)
    FROM msdb.dbo.restorehistory
    WHERE restore_date >= DATEADD(DAY, -90, GETDATE())
      AND restore_type = 'V';

    SELECT @LastRestoreDate = MAX(restore_date)
    FROM msdb.dbo.restorehistory;

    IF @LastRestoreDate IS NOT NULL
        SET @DaysSinceLastRestore = DATEDIFF(DAY, @LastRestoreDate, GETDATE());

    SELECT @DbsTested90 = COUNT(*)
    FROM @TestedDbs AS t
    INNER JOIN @BackedUpDbs AS b
        ON b.database_name = t.database_name;

    SET @TestedList = STUFF((
        SELECT TOP (20) N', ' + t.database_name
        FROM @TestedDbs AS t
        INNER JOIN @BackedUpDbs AS b
            ON b.database_name = t.database_name
        ORDER BY t.database_name
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(2000)'), 1, 2, N'');

    SET @UntestedList = STUFF((
        SELECT TOP (20) N', ' + b.database_name
        FROM @BackedUpDbs AS b
        WHERE NOT EXISTS (SELECT 1 FROM @TestedDbs AS t WHERE t.database_name = b.database_name)
        ORDER BY b.database_name
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(2000)'), 1, 2, N'');

    SET @TestedList   = ISNULL(@TestedList,   N'none');
    SET @UntestedList = ISNULL(@UntestedList, N'none');

    IF @DbsWithBackups = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = N'No full backups were found in msdb.dbo.backupset for any user database in the last 365 days, '
                     + N'so there is nothing to restore-test. Total restore/verify events ever recorded on this instance: '
                     + CAST(@TotalRestoreEvents AS NVARCHAR(20)) + N'.';
    END
    ELSE IF @TotalRestoreEvents = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = N'msdb.dbo.restorehistory contains no restore or RESTORE VERIFYONLY events at all, while '
                     + CAST(@DbsWithBackups AS NVARCHAR(20)) + N' user database(s) have full backups in the last 365 days ('
                     + @UntestedList + N'). Backups are being taken but have never been proven recoverable on this instance.';
    END
    ELSE IF @RestoreEvents90 > 0 AND @DbsTested90 >= @DbsWithBackups
    BEGIN
        SET @Score = 3;
        SET @Finding = N'Restore testing is current and complete: ' + CAST(@RestoreEvents90 AS NVARCHAR(20))
                     + N' restore/verify event(s) in the last 90 days (of which ' + CAST(@VerifyOnlyEvents90 AS NVARCHAR(20))
                     + N' were RESTORE VERIFYONLY), covering all ' + CAST(@DbsWithBackups AS NVARCHAR(20))
                     + N' backed-up user database(s): ' + @TestedList + N'. Most recent event '
                     + CONVERT(NVARCHAR(20), @LastRestoreDate, 120) + N' ('
                     + CAST(@DaysSinceLastRestore AS NVARCHAR(20)) + N' day(s) ago).';
    END
    ELSE IF @RestoreEvents90 > 0
    BEGIN
        SET @Score = 2;
        SET @Finding = N'Restore testing is recent but incomplete: ' + CAST(@RestoreEvents90 AS NVARCHAR(20))
                     + N' restore/verify event(s) in the last 90 days covering only ' + CAST(@DbsTested90 AS NVARCHAR(20))
                     + N' of ' + CAST(@DbsWithBackups AS NVARCHAR(20)) + N' backed-up user database(s). Tested: '
                     + @TestedList + N'. Not restore-tested in the last 90 days: ' + @UntestedList
                     + N'. Most recent event ' + CONVERT(NVARCHAR(20), @LastRestoreDate, 120) + N'.';
    END
    ELSE IF @RestoreEvents365 > 0
    BEGIN
        SET @Score = 1;
        SET @Finding = N'Restore testing is stale: the last restore/verify event was '
                     + CONVERT(NVARCHAR(20), @LastRestoreDate, 120) + N' ('
                     + CAST(@DaysSinceLastRestore AS NVARCHAR(20)) + N' day(s) ago) with no activity in the last 90 days. '
                     + CAST(@DbsWithBackups AS NVARCHAR(20)) + N' user database(s) are being backed up: ' + @UntestedList + N'.';
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = N'No restore or RESTORE VERIFYONLY activity in the last 365 days. Last recorded event: '
                     + ISNULL(CONVERT(NVARCHAR(20), @LastRestoreDate, 120), N'never') + N'. '
                     + CAST(@DbsWithBackups AS NVARCHAR(20)) + N' user database(s) have recent full backups that have '
                     + N'never been verified by restore: ' + @UntestedList + N'.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    CAST(@Result AS NVARCHAR(50))           AS Result,
    CAST(@Score AS INT)                     AS Score,
    CAST(@DatabaseQueried AS NVARCHAR(256)) AS DatabaseQueried,
    CAST(@Finding AS NVARCHAR(4000))        AS Finding;