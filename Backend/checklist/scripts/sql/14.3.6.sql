-- Checklist: Reporting workloads isolated from write workloads (read replicas) where possible
-- Scope: SERVER
-- Scoring: 3 = readable secondary replicas exist and read-only routing is configured; 2 = readable secondaries or routing entries exist, or Azure SQL Database where read scale-out is platform provided; 1 = availability replicas exist but none is readable and no routing is configured; 0 = no availability replicas, or the availability metadata could not be read

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Read replica evidence could not be read';
DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Replicas INT = 0;
DECLARE @Readable INT = 0;
DECLARE @Routing INT = 0;
DECLARE @ReadableNames NVARCHAR(MAX) = '';
DECLARE @Read BIT = 0;

DECLARE @Ag TABLE (
    ReplicaName NVARCHAR(256) NOT NULL,
    AllowsReadConnections INT NOT NULL);

-- The availability catalog views do not exist on Azure SQL Database, so the probe runs
-- through read-only dynamic SQL and is skipped entirely on that engine edition.
IF @Edition <> 5
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT r.replica_server_name,
                            CASE WHEN r.secondary_role_allow_connections_desc <> ''NO'' THEN 1 ELSE 0 END
                     FROM sys.availability_replicas AS r;';

        INSERT INTO @Ag (ReplicaName, AllowsReadConnections)
        EXEC sys.sp_executesql @Sql;

        SET @Sql = N'SELECT @c = COUNT(*) FROM sys.availability_read_only_routing_lists;';
        EXEC sys.sp_executesql @Sql, N'@c INT OUTPUT', @c = @Routing OUTPUT;

        SET @Read = 1;
    END TRY
    BEGIN CATCH
        SET @Read = 0;
    END CATCH;
END

SET @Routing = ISNULL(@Routing, 0);

SELECT @Replicas = COUNT(*),
       @Readable = ISNULL(SUM(AllowsReadConnections), 0)
FROM @Ag;

SELECT @ReadableNames = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), ReplicaName), ', '), 300), 'none')
FROM @Ag
WHERE AllowsReadConnections = 1;

SET @Score = CASE
    WHEN @Edition = 5 THEN 2
    WHEN @Read = 0 THEN 0
    WHEN @Readable > 0 AND @Routing > 0 THEN 3
    WHEN @Readable > 0 OR @Routing > 0 THEN 2
    WHEN @Replicas > 0 THEN 1
    ELSE 0
END;

SET @Finding = CASE
    WHEN @Edition = 5
        THEN 'Azure SQL Database: availability replica metadata is not exposed; read-only routing to a read scale-out replica is provided by the platform through ApplicationIntent=ReadOnly'
    WHEN @Read = 0
        THEN 'sys.availability_replicas could not be read; read replica configuration is unknown'
    ELSE CONCAT(
        'availability replicas = ', @Replicas,
        '; replicas accepting read-only connections = ', @Readable, ' (', @ReadableNames, ')',
        '; read-only routing list entries = ', @Routing)
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
