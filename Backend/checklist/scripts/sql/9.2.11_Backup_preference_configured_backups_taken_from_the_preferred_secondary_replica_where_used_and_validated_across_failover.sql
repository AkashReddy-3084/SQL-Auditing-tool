SET NOCOUNT ON;
-- Checklist: Backup preference configured (backups taken from the preferred / secondary replica where used) and validated across failover
-- Scope: SERVER
-- Scoring: 0 = No AGs configured or feature unavailable; 1 = AGs exist but backup preference is 'Primary'; 2 = Preference allows secondary backups and recent backups verified. Max capped at 2 because full failover validation requires manual testing/monitoring.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

-- Platform compatibility: sys.availability_groups is a server-level view. Must check in master.sys to avoid false negatives.
IF OBJECT_ID('master.sys.availability_groups') IS NOT NULL
BEGIN
    DECLARE @AgCount INT = 0;
    DECLARE @SecondaryPrefCount INT = 0;
    DECLARE @BackupCount INT = 0;

    SELECT @AgCount = COUNT(*) FROM sys.availability_groups;

    IF @AgCount > 0
    BEGIN
        -- Check if backup preference allows secondary replicas
        SELECT @SecondaryPrefCount = COUNT(*) 
        FROM sys.availability_groups 
        WHERE backup_pref_desc IN ('Secondary', 'Secondary/With Low Priority');

        -- Validate recent backups for AG databases (last 7 days)
        SELECT @BackupCount = COUNT(*)
        FROM msdb.dbo.backupset b
        INNER JOIN sys.databases d ON b.database_name = d.name
        INNER JOIN sys.availability_groups_databases agd ON d.name = agd.database_name
        WHERE b.type IN ('D', 'I', 'L') 
          AND b.backup_start_date >= DATEADD(day, -7, GETDATE());

        IF @SecondaryPrefCount = @AgCount AND @BackupCount > 0
            SET @Score = 2;
        ELSE IF @SecondaryPrefCount = @AgCount AND @BackupCount = 0
            SET @Score = 1;
        ELSE IF @SecondaryPrefCount < @AgCount
            SET @Score = 1;
    END
    ELSE
    BEGIN
        SET @Score = 0;
    END
END
ELSE
BEGIN
    SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;
-- NOTE: This script provides automated evidence. Full compliance requires human review of failover test results and backup job logs.