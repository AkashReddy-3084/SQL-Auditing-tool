-- Checklist: Secondary region/replica capacity provisioned or evaluated
-- Scope: SERVER
-- Scoring: 3 = a connected secondary replica or geo-replication link is detected; 2 = reserved; 1 = configured but not currently connected; 0 = no secondary replica/geo-replication mechanism detected
-- NOTE: Automated evidence only; whether secondary capacity sizing was formally evaluated against expected failover load is not independently verified. Full compliance requires human review.

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
    SET @Finding = CASE WHEN ISNULL(@GeoLinkCount,0) = 0 THEN 'No geo-replication secondary configured'
                        ELSE CONCAT('Geo-replication links = ', @GeoLinkCount, ', currently healthy/connected = ', ISNULL(@HealthyGeoLinkCount,0)) END;
END
ELSE
BEGIN
    DECLARE @SecondaryReplicaCount INT = 0, @ConnectedSecondaryCount INT = 0;

    IF OBJECT_ID('sys.availability_replicas') IS NOT NULL
    BEGIN
        SELECT @SecondaryReplicaCount = COUNT(*)
        FROM sys.availability_replicas ar
        WHERE ar.replica_server_name <> CAST(SERVERPROPERTY('ServerName') AS SYSNAME);

        SELECT @ConnectedSecondaryCount = COUNT(*)
        FROM sys.availability_replicas ar
        JOIN sys.dm_hadr_availability_replica_states rs ON rs.replica_id = ar.replica_id
        WHERE ar.replica_server_name <> CAST(SERVERPROPERTY('ServerName') AS SYSNAME) AND rs.connected_state = 1;
    END

    SET @Score = CASE WHEN ISNULL(@SecondaryReplicaCount,0) = 0 THEN 0
                      WHEN ISNULL(@ConnectedSecondaryCount,0) > 0 THEN 3
                      ELSE 1 END;
    SET @Finding = CASE WHEN ISNULL(@SecondaryReplicaCount,0) = 0 THEN 'No secondary Availability Group replica configured'
                        ELSE CONCAT('Secondary replicas configured = ', @SecondaryReplicaCount, ', currently connected = ', ISNULL(@ConnectedSecondaryCount,0)) END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;