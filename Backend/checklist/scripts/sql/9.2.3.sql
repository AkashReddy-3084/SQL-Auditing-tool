-- Checklist: Geo-replication / failover group configured for DR where required
-- Scope: SERVER
-- Scoring: 3 = a healthy geo-replication link (Azure SQL DB) or asynchronous DR AG replica (on-prem/MI) is detected; 2 = reserved; 1 = a mechanism is configured but appears unhealthy; 0 = no DR replication mechanism detected
-- NOTE: Automated evidence only; whether DR replication is "required" for this specific workload per policy is not independently verified. Full compliance requires human review.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX);

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    DECLARE @GeoLinkCount INT = 0, @HealthyGeoLinkCount INT = 0;

    IF OBJECT_ID('sys.geo_replication_links') IS NOT NULL
    BEGIN
        SELECT @GeoLinkCount = COUNT(*) FROM sys.geo_replication_links;

        IF OBJECT_ID('sys.dm_geo_replication_link_status') IS NOT NULL
            SELECT @HealthyGeoLinkCount = COUNT(*) FROM sys.dm_geo_replication_link_status WHERE replication_state = 2;
    END

    SET @Score = CASE WHEN ISNULL(@GeoLinkCount,0) = 0 THEN 0
                      WHEN ISNULL(@HealthyGeoLinkCount,0) > 0 THEN 3
                      ELSE 1 END;
    SET @Finding = CASE WHEN ISNULL(@GeoLinkCount,0) = 0 THEN 'No geo-replication link configured'
                        ELSE CONCAT('Geo-replication links = ', @GeoLinkCount, ', in healthy CATCH_UP/replicating state = ', ISNULL(@HealthyGeoLinkCount,0)) END;
END
ELSE
BEGIN
    DECLARE @AsyncReplicaCount INT = 0;

    IF OBJECT_ID('sys.dm_hadr_availability_replica_states') IS NOT NULL
        SELECT @AsyncReplicaCount = COUNT(*)
        FROM sys.availability_replicas ar
        JOIN sys.dm_hadr_availability_replica_states rs ON rs.replica_id = ar.replica_id
        WHERE ar.availability_mode_desc = 'ASYNCHRONOUS_COMMIT' AND rs.connected_state = 1;

    SET @Score = CASE WHEN ISNULL(@AsyncReplicaCount,0) = 0 THEN 0
                      ELSE 3 END;
    SET @Finding = CASE WHEN ISNULL(@AsyncReplicaCount,0) = 0 THEN 'No asynchronous-commit DR replica detected'
                        ELSE CONCAT('Connected asynchronous-commit (DR) replicas = ', @AsyncReplicaCount) END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;