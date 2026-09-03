-- Checklist: HA approach defined and matches SLA (Always On AG / failover cluster / zone-redundant / failover groups)
-- Scope: SERVER
-- Scoring: 3 = an availability group with a synchronous secondary, a multi-node failover cluster, or an Azure SQL Database geo/failover-group secondary is active; 2 = HA is present but single-topology, or Azure SQL Database on a production tier where HA is platform-managed; 1 = HA capability is switched on with no topology built, or a low Azure tier; 0 = no HA evidence at all

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'HA evidence could not be collected';
DECLARE @Engine INT = ISNULL(CONVERT(INT, SERVERPROPERTY('EngineEdition')), 0);
DECLARE @Edition NVARCHAR(128) = ISNULL(CONVERT(NVARCHAR(128), SERVERPROPERTY('Edition')), N'(unknown)');
DECLARE @HadrEnabled INT = ISNULL(CONVERT(INT, SERVERPROPERTY('IsHadrEnabled')), 0);
DECLARE @IsClustered INT = ISNULL(CONVERT(INT, SERVERPROPERTY('IsClustered')), 0);
DECLARE @AgCount INT = 0;
DECLARE @SyncSecondaries INT = 0;
DECLARE @ClusterNodes INT = 0;
DECLARE @GeoLinks INT = 0;
DECLARE @Tier NVARCHAR(200) = N'(unknown)';
DECLARE @Warn NVARCHAR(1000) = N'';
DECLARE @Sql NVARCHAR(MAX);

IF @Engine = 5
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT @out = COUNT(*) FROM sys.geo_replication_links;';
        EXEC sys.sp_executesql @Sql, N'@out INT OUTPUT', @out = @GeoLinks OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Warn = N'geo_replication_links unavailable: ' + ERROR_MESSAGE();
    END CATCH;

    BEGIN TRY
        SET @Sql = N'SELECT @out = ISNULL(MAX(CONVERT(NVARCHAR(200), edition + N''/'' + service_objective)), N''(unknown)'') FROM sys.database_service_objectives;';
        EXEC sys.sp_executesql @Sql, N'@out NVARCHAR(200) OUTPUT', @out = @Tier OUTPUT;
    END TRY
    BEGIN CATCH
        IF @Warn = N'' SET @Warn = N'service objective unavailable: ' + ERROR_MESSAGE();
    END CATCH;

    SET @Score = CASE
        WHEN @GeoLinks > 0 THEN 3
        WHEN @Tier LIKE N'%Basic%' OR @Tier LIKE N'%/S0%' OR @Tier LIKE N'%Free%' THEN 1
        ELSE 2 END;

    SET @Finding = CONCAT(N'Azure SQL Database (', @Edition, N'), service objective = ', @Tier,
        N'; active geo-replication / failover-group links = ', @GeoLinks,
        N'; HA within a region is platform-managed');
END
ELSE
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT @out = COUNT(*) FROM sys.availability_groups;';
        EXEC sys.sp_executesql @Sql, N'@out INT OUTPUT', @out = @AgCount OUTPUT;

        SET @Sql = N'SELECT @out = COUNT(*) FROM sys.dm_hadr_availability_replica_states AS s
                     JOIN sys.availability_replicas AS r ON r.replica_id = s.replica_id
                     WHERE s.role = 2 AND r.availability_mode = 1;';
        EXEC sys.sp_executesql @Sql, N'@out INT OUTPUT', @out = @SyncSecondaries OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Warn = N'availability-group views unavailable: ' + ERROR_MESSAGE();
    END CATCH;

    BEGIN TRY
        SET @Sql = N'SELECT @out = COUNT(*) FROM sys.dm_os_cluster_nodes;';
        EXEC sys.sp_executesql @Sql, N'@out INT OUTPUT', @out = @ClusterNodes OUTPUT;
    END TRY
    BEGIN CATCH
        IF @Warn = N'' SET @Warn = N'cluster node DMV unavailable: ' + ERROR_MESSAGE();
    END CATCH;

    SET @Score = CASE
        WHEN @AgCount > 0 AND @SyncSecondaries > 0 THEN 3
        WHEN @IsClustered = 1 AND @ClusterNodes > 1 THEN 3
        WHEN @AgCount > 0 OR @ClusterNodes > 1 THEN 2
        WHEN @Engine = 8 THEN 2
        WHEN @HadrEnabled = 1 OR @IsClustered = 1 THEN 1
        ELSE 0 END;

    SET @Finding = CONCAT(CASE WHEN @Engine = 8 THEN N'Azure SQL Managed Instance (' ELSE N'SQL Server (' END,
        @Edition, N'): availability groups = ', @AgCount,
        N', synchronous secondary replicas = ', @SyncSecondaries,
        N', failover cluster nodes = ', @ClusterNodes,
        N', IsHadrEnabled = ', @HadrEnabled, N', IsClustered = ', @IsClustered);
END

IF @Warn <> N'' SET @Finding = @Finding + N'; probe note: ' + @Warn;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
