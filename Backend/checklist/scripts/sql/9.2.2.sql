-- Checklist: HA solution matches SLA (Always On AG / failover groups / zone redundancy)
-- Scope: SERVER
-- Scoring: 3 = a healthy HA mechanism (AG with 2+ synchronized replicas, zone redundancy, or geo-replication) is detected; 2 = an HA mechanism exists but with limited/degraded coverage; 1 = reserved; 0 = no HA mechanism detected
-- NOTE: Automated evidence only; whether the detected HA configuration satisfies a specific documented SLA number is not independently verified. Full compliance requires human review.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX);

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    DECLARE @ZoneRedundantCount INT = 0, @GeoReplicaCount INT = 0, @TotalDbCount INT = 0;

    SELECT @TotalDbCount = COUNT(*) FROM sys.databases WHERE database_id > 4 AND state = 0;

    IF COL_LENGTH('sys.databases', 'is_zone_redundant') IS NOT NULL
        SELECT @ZoneRedundantCount = COUNT(*) FROM sys.databases WHERE database_id > 4 AND state = 0 AND is_zone_redundant = 1;

    IF OBJECT_ID('sys.geo_replication_links') IS NOT NULL
        SELECT @GeoReplicaCount = COUNT(*) FROM sys.geo_replication_links;

    SET @Score = CASE WHEN ISNULL(@TotalDbCount,0) = 0 THEN 0
                      WHEN ISNULL(@ZoneRedundantCount,0) > 0 OR ISNULL(@GeoReplicaCount,0) > 0 THEN 3
                      ELSE 0 END;
    SET @Finding = CASE WHEN ISNULL(@TotalDbCount,0) = 0 THEN 'No user databases found'
                        ELSE CONCAT('Databases = ', @TotalDbCount, ', zone-redundant = ', ISNULL(@ZoneRedundantCount,0), ', geo-replication links = ', ISNULL(@GeoReplicaCount,0)) END;
END
ELSE
BEGIN
    DECLARE @AgCount INT = 0, @SyncedReplicaCount INT = 0;

    IF OBJECT_ID('sys.availability_groups') IS NOT NULL
    BEGIN
        SELECT @AgCount = COUNT(*) FROM sys.availability_groups;

        SELECT @SyncedReplicaCount = COUNT(*)
        FROM sys.dm_hadr_availability_replica_states rs
        WHERE rs.role_desc IS NOT NULL AND rs.connected_state = 1;
    END

    SET @Score = CASE WHEN ISNULL(@AgCount,0) = 0 THEN 0
                      WHEN ISNULL(@SyncedReplicaCount,0) >= 2 THEN 3
                      WHEN ISNULL(@SyncedReplicaCount,0) = 1 THEN 2
                      ELSE 0 END;
    SET @Finding = CASE WHEN ISNULL(@AgCount,0) = 0 THEN 'No Always On Availability Group configured'
                        ELSE CONCAT('Availability Groups = ', @AgCount, ', connected replicas = ', ISNULL(@SyncedReplicaCount,0)) END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;