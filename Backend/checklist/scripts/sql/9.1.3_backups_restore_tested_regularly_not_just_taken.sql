-- Checklist: Backups restore-tested regularly (not just taken)
-- Scope: SERVER
-- Scoring: 3=Restores in last 30 days; 2=Restores in last 90 days or Azure SQL DB platform-managed; 1=Backups exist but no recent restores; 0=No backups or restores in 180 days.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

SET @DatabaseQueried = 'master';

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: Backup/restore is platform-managed
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database: Backup and restore operations are fully platform-managed. Manual restore testing is not exposed via queryable artifacts.';
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI
    DECLARE @Restores30 INT = 0;
    DECLARE @Restores90 INT = 0;
    DECLARE @Restores180 INT = 0;
    DECLARE @Backups90 INT = 0;

    IF OBJECT_ID('msdb.dbo.restorehistory') IS NOT NULL
    BEGIN
        SELECT @Restores30 = COUNT(*) FROM msdb.dbo.restorehistory
        WHERE restore_date >= DATEADD(day, -30, GETDATE())
          AND destination_database_name NOT IN ('master', 'model', 'msdb', 'tempdb');

        SELECT @Restores90 = COUNT(*) FROM msdb.dbo.restorehistory
        WHERE restore_date >= DATEADD(day, -90, GETDATE())
          AND destination_database_name NOT IN ('master', 'model', 'msdb', 'tempdb');

        SELECT @Restores180 = COUNT(*) FROM msdb.dbo.restorehistory
        WHERE restore_date >= DATEADD(day, -180, GETDATE())
          AND destination_database_name NOT IN ('master', 'model', 'msdb', 'tempdb');
    END

    IF OBJECT_ID('msdb.dbo.backupset') IS NOT NULL
    BEGIN
        SELECT @Backups90 = COUNT(*) FROM msdb.dbo.backupset
        WHERE backup_start_date >= DATEADD(day, -90, GETDATE())
          AND type IN ('D', 'I', 'L');
    END

    IF @Restores30 > 0
    BEGIN
        SET @Score = 3;
        SET @Finding = 'Restore testing verified: ' + CAST(@Restores30 AS NVARCHAR(10)) + ' restore(s) performed in the last 30 days.';
    END
    ELSE IF @Restores90 > 0
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Partial evidence: ' + CAST(@Restores90 AS NVARCHAR(10)) + ' restore(s) in last 90 days. Regular testing not confirmed.';
    END
    ELSE IF @Backups90 > 0
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Backups are taken (' + CAST(@Backups90 AS NVARCHAR(10)) + ' in last 90 days), but no restore tests found in last 90 days.';
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No recent backups or restore tests found in the last 180 days.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;