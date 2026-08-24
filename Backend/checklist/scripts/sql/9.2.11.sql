-- Checklist: Backup preference configured (backups taken from the preferred / secondary replica where used) and validated across failover
-- Scope: SERVER
-- Scoring: 3 = backup preference is configured and a suitable replica exists to satisfy it (or Azure SQL DB platform-managed); 2 = reserved; 1 = preference favors a secondary but no connected secondary exists; 0 = no AG configured and not Azure SQL Database
-- NOTE: Automated evidence only; whether this configuration was validated by actually performing a failover drill is not independently verified. Full compliance requires human review.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX);

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Score = 3;
    SET @Finding = 'Azure SQL Database: backup execution location is platform-managed';
END
ELSE
BEGIN
    DECLARE @AgCount INT = 0, @Preference NVARCHAR(60), @ConnectedSecondaryCount INT = 0;

    IF OBJECT_ID('sys.availability_groups') IS NOT NULL
    BEGIN
        SELECT TOP 1 @AgCount = 1, @Preference = automated_backup_preference_desc FROM sys.availability_groups;

        SELECT @ConnectedSecondaryCount = COUNT(*)
        FROM sys.availability_replicas ar
        JOIN sys.dm_hadr_availability_replica_states rs ON rs.replica_id = ar.replica_id
        WHERE ar.replica_server_name <> CAST(SERVERPROPERTY('ServerName') AS SYSNAME) AND rs.connected_state = 1;
    END

    SET @Score = CASE WHEN ISNULL(@AgCount,0) = 0 THEN 0
                      WHEN @Preference IN ('SECONDARY','SECONDARY_ONLY') AND ISNULL(@ConnectedSecondaryCount,0) = 0 THEN 1
                      ELSE 3 END;
    SET @Finding = CASE WHEN ISNULL(@AgCount,0) = 0 THEN 'No Availability Group configured'
                        ELSE CONCAT('automated_backup_preference = ', ISNULL(@Preference,'unknown'), ', connected secondary replicas = ', ISNULL(@ConnectedSecondaryCount,0)) END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;