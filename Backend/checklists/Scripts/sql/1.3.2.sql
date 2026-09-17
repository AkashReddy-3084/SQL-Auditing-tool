-- Checklist: Redundancy configured for the production database (replicas / zone redundancy)
-- Scope: SERVER
-- Scoring: 3 = two or more availability replicas host databases, or an Azure zone-redundant / geo-replicated database exists; 2 = a single secondary copy exists via one replica, mirroring, log shipping, or an Azure production tier; 1 = only a shared-storage cluster or a low Azure tier, giving no second data copy; 0 = no redundancy evidence

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Redundancy evidence could not be collected';
DECLARE @Engine INT = ISNULL(CONVERT(INT, SERVERPROPERTY('EngineEdition')), 0);
DECLARE @Edition NVARCHAR(128) = ISNULL(CONVERT(NVARCHAR(128), SERVERPROPERTY('Edition')), N'(unknown)');
DECLARE @IsClustered INT = ISNULL(CONVERT(INT, SERVERPROPERTY('IsClustered')), 0);
DECLARE @Replicas INT = 0;
DECLARE @ReplicatedDbs INT = 0;
DECLARE @Mirrored INT = 0;
DECLARE @LogShipped INT = 0;
DECLARE @ZoneRedundant INT = 0;
DECLARE @GeoLinks INT = 0;
DECLARE @Tier NVARCHAR(200) = N'(unknown)';
DECLARE @Warn NVARCHAR(1000) = N'';
DECLARE @Sql NVARCHAR(MAX);

IF @Engine = 5
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT @out = COUNT(*) FROM sys.databases WHERE database_id > 1 AND is_zone_redundant = 1;';
        EXEC sys.sp_executesql @Sql, N'@out INT OUTPUT', @out = @ZoneRedundant OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Warn = N'zone redundancy flag unavailable: ' + ERROR_MESSAGE();
    END CATCH;

    BEGIN TRY
        SET @Sql = N'SELECT @out = COUNT(*) FROM sys.geo_replication_links;';
        EXEC sys.sp_executesql @Sql, N'@out INT OUTPUT', @out = @GeoLinks OUTPUT;
    END TRY
    BEGIN CATCH
        IF @Warn = N'' SET @Warn = N'geo_replication_links unavailable: ' + ERROR_MESSAGE();
    END CATCH;

    BEGIN TRY
        SET @Sql = N'SELECT @out = ISNULL(MAX(CONVERT(NVARCHAR(200), edition + N''/'' + service_objective)), N''(unknown)'') FROM sys.database_service_objectives;';
        EXEC sys.sp_executesql @Sql, N'@out NVARCHAR(200) OUTPUT', @out = @Tier OUTPUT;
    END TRY
    BEGIN CATCH
        IF @Warn = N'' SET @Warn = N'service objective unavailable: ' + ERROR_MESSAGE();
    END CATCH;

    SET @Score = CASE
        WHEN @ZoneRedundant > 0 OR @GeoLinks > 0 THEN 3
        WHEN @Tier LIKE N'%Basic%' OR @Tier LIKE N'%/S0%' OR @Tier LIKE N'%Free%' THEN 1
        ELSE 2 END;

    SET @Finding = CONCAT(N'Azure SQL Database (', @Edition, N'), service objective = ', @Tier,
        N'; zone-redundant databases = ', @ZoneRedundant,
        N'; geo-replication / failover-group links = ', @GeoLinks);
END
ELSE
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT @out = COUNT(*) FROM sys.availability_replicas;';
        EXEC sys.sp_executesql @Sql, N'@out INT OUTPUT', @out = @Replicas OUTPUT;

        SET @Sql = N'SELECT @out = COUNT(DISTINCT database_id) FROM sys.dm_hadr_database_replica_states WHERE is_local = 1;';
        EXEC sys.sp_executesql @Sql, N'@out INT OUTPUT', @out = @ReplicatedDbs OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Warn = N'availability replica views unavailable: ' + ERROR_MESSAGE();
    END CATCH;

    BEGIN TRY
        SET @Sql = N'SELECT @out = COUNT(*) FROM sys.database_mirroring WHERE mirroring_guid IS NOT NULL;';
        EXEC sys.sp_executesql @Sql, N'@out INT OUTPUT', @out = @Mirrored OUTPUT;
    END TRY
    BEGIN CATCH
        IF @Warn = N'' SET @Warn = N'mirroring view unavailable: ' + ERROR_MESSAGE();
    END CATCH;

    BEGIN TRY
        IF OBJECT_ID('msdb.dbo.log_shipping_primary_databases') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT @out = COUNT(*) FROM msdb.dbo.log_shipping_primary_databases;';
            EXEC sys.sp_executesql @Sql, N'@out INT OUTPUT', @out = @LogShipped OUTPUT;
        END
    END TRY
    BEGIN CATCH
        IF @Warn = N'' SET @Warn = N'log shipping tables unavailable: ' + ERROR_MESSAGE();
    END CATCH;

    SET @Score = CASE
        WHEN @Replicas >= 2 AND @ReplicatedDbs > 0 THEN 3
        WHEN @Replicas >= 2 OR @Mirrored > 0 OR @LogShipped > 0 OR @Engine = 8 THEN 2
        WHEN @Replicas = 1 OR @IsClustered = 1 THEN 1
        ELSE 0 END;

    SET @Finding = CONCAT(CASE WHEN @Engine = 8 THEN N'Azure SQL Managed Instance (' ELSE N'SQL Server (' END,
        @Edition, N'): availability replicas = ', @Replicas,
        N', databases joined to a local replica = ', @ReplicatedDbs,
        N', mirrored databases = ', @Mirrored,
        N', log-shipped primaries = ', @LogShipped,
        N', IsClustered = ', @IsClustered);
END

IF @Warn <> N'' SET @Finding = @Finding + N'; probe note: ' + @Warn;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
