-- Checklist: Backup preference configured (backups taken from the preferred / secondary replica where used) and validated across failover
-- Scope: SERVER
-- Scoring: 0: All AGs Primary-only. 1: Mixed preferences. 2: All Secondary/Any but no recent secondary backups. 3: All Secondary/Any with recent secondary backups. (Failover validation requires manual testing.)
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

IF @EngineEdition = 5
BEGIN
    SET @Score = 3;
    SET @Finding = 'Azure SQL Database: High availability and backup management are platform-managed. Manual backup preference configuration is not applicable.';
END
ELSE
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.availability_groups)
    BEGIN
        SET @Score = 3;
        SET @Finding = 'No Always On Availability Groups configured. Check not applicable.';
    END
    ELSE
    BEGIN
        CREATE TABLE #AgStatus (
            AgName NVARCHAR(128),
            BackupPref INT,
            PrimaryReplica NVARCHAR(128)
        );

        INSERT INTO #AgStatus
        SELECT 
            ag.name,
            ag.backup_preference,
            ags.primary_replica
        FROM sys.availability_groups ag
        JOIN sys.dm_hadr_availability_group_states ags ON ag.group_id = ags.group_id;

        DECLARE @AgCount INT = (SELECT COUNT(*) FROM #AgStatus);
        DECLARE @SecondaryPrefCount INT = (SELECT COUNT(*) FROM #AgStatus WHERE BackupPref IN (2, 3));
        DECLARE @SecondaryBackupCount INT = 0;

        BEGIN TRY
            SELECT @SecondaryBackupCount = COUNT(DISTINCT bs.server_name)
            FROM msdb.dbo.backupset bs
            WHERE bs.type IN ('D', 'I', 'L')
              AND bs.backup_start_date >= DATEADD(day, -7, GETDATE())
              AND NOT EXISTS (
                  SELECT 1 FROM #AgStatus a WHERE a.PrimaryReplica = bs.server_name
              );
        END TRY
        BEGIN CATCH
            SET @SecondaryBackupCount = 0;
        END CATCH;

        IF @SecondaryPrefCount = @AgCount AND @SecondaryBackupCount > 0
        BEGIN
            SET @Score = 3;
            SET @Finding = 'All AGs configured for Secondary/Any backup preference. Recent backups confirmed from secondary replicas.';
        END
        ELSE IF @SecondaryPrefCount = @AgCount AND @SecondaryBackupCount = 0
        BEGIN
            SET @Score = 2;
            SET @Finding = 'All AGs configured for Secondary/Any backup preference. No recent backups found from secondary replicas in the last 7 days.';
        END
        ELSE IF @SecondaryPrefCount > 0 AND @SecondaryPrefCount < @AgCount
        BEGIN
            SET @Score = 1;
            SET @Finding = 'Mixed backup preferences across AGs. ' + CAST(@SecondaryPrefCount AS NVARCHAR) + ' of ' + CAST(@AgCount AS NVARCHAR) + ' AGs set to Secondary/Any.';
        END
        ELSE
        BEGIN
            SET @Score = 0;
            SET @Finding = 'All AGs configured for Primary-only backup preference. No secondary backup preference configured.';
        END

        DROP TABLE #AgStatus;
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;