/*
    Checklist 9.2.3 - Geo-replication / failover group configured for DR where required
    Scope: SERVER. Strictly read-only.
*/
SET NOCOUNT ON;

DECLARE @Result NVARCHAR(50) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(256) = N'None';
DECLARE @Finding NVARCHAR(MAX) = N'Unable to determine the disaster-recovery replication configuration.';

DECLARE @Engine INT = ISNULL(CAST(SERVERPROPERTY('EngineEdition') AS INT), 0);
DECLARE @sql NVARCHAR(MAX);
DECLARE @GeoLinks INT = 0;
DECLARE @GeoCatchUp INT = 0;
DECLARE @GeoSeeding INT = 0;
DECLARE @GeoDetail NVARCHAR(2000) = N'none';
DECLARE @AsyncReplicas INT = 0;
DECLARE @SyncReplicas INT = 0;
DECLARE @UnhealthyReplicas INT = 0;
DECLARE @DistributedReplicas INT = 0;
DECLARE @AgDetail NVARCHAR(2000) = N'none';
DECLARE @LogShipDbs INT = 0;

IF @Engine = 5
BEGIN
    SET @DatabaseQueried = ISNULL(DB_NAME(), N'Unknown');

    IF OBJECT_ID(N'sys.dm_geo_replication_link_status') IS NOT NULL
    BEGIN
        SET @sql = N'SELECT @links = COUNT(*),
       @catchup = ISNULL(SUM(CASE WHEN l.replication_state_desc = ''CATCH_UP'' THEN 1 ELSE 0 END), 0),
       @seeding = ISNULL(SUM(CASE WHEN l.replication_state_desc = ''SEEDING'' THEN 1 ELSE 0 END), 0),
       @detail = ISNULL(STUFF((SELECT '', '' + l2.partner_server + ''.'' + l2.partner_database + '' ['' + ISNULL(l2.role_desc, ''UNKNOWN'') + ''/'' + ISNULL(l2.replication_state_desc, ''UNKNOWN'') + '']''
                               FROM sys.dm_geo_replication_link_status AS l2
                               FOR XML PATH(''''), TYPE).value(''.'', ''nvarchar(max)''), 1, 2, ''''), ''none'')
FROM sys.dm_geo_replication_link_status AS l;';

        EXEC sys.sp_executesql @sql,
             N'@links INT OUTPUT, @catchup INT OUTPUT, @seeding INT OUTPUT, @detail NVARCHAR(2000) OUTPUT',
             @links = @GeoLinks OUTPUT, @catchup = @GeoCatchUp OUTPUT, @seeding = @GeoSeeding OUTPUT, @detail = @GeoDetail OUTPUT;
    END
    ELSE IF OBJECT_ID(N'sys.geo_replication_links') IS NOT NULL
    BEGIN
        SET @sql = N'SELECT @links = COUNT(*),
       @catchup = ISNULL(SUM(CASE WHEN l.replication_state_desc = ''CATCH_UP'' THEN 1 ELSE 0 END), 0),
       @seeding = ISNULL(SUM(CASE WHEN l.replication_state_desc = ''SEEDING'' THEN 1 ELSE 0 END), 0),
       @detail = ISNULL(STUFF((SELECT '', '' + l2.partner_server + ''.'' + l2.partner_database + '' ['' + ISNULL(l2.role_desc, ''UNKNOWN'') + ''/'' + ISNULL(l2.replication_state_desc, ''UNKNOWN'') + '']''
                               FROM sys.geo_replication_links AS l2
                               FOR XML PATH(''''), TYPE).value(''.'', ''nvarchar(max)''), 1, 2, ''''), ''none'')
FROM sys.geo_replication_links AS l;';

        EXEC sys.sp_executesql @sql,
             N'@links INT OUTPUT, @catchup INT OUTPUT, @seeding INT OUTPUT, @detail NVARCHAR(2000) OUTPUT',
             @links = @GeoLinks OUTPUT, @catchup = @GeoCatchUp OUTPUT, @seeding = @GeoSeeding OUTPUT, @detail = @GeoDetail OUTPUT;
    END

    SET @GeoLinks = ISNULL(@GeoLinks, 0);
    SET @GeoCatchUp = ISNULL(@GeoCatchUp, 0);
    SET @GeoSeeding = ISNULL(@GeoSeeding, 0);
    SET @GeoDetail = ISNULL(@GeoDetail, N'none');

    IF @GeoLinks = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = N'Azure SQL Database [' + @DatabaseQueried + N']: no geo-replication link or auto-failover group partnership is present, so there is no cross-region DR replica. Confirm whether DR is required for this database.';
    END
    ELSE IF @GeoCatchUp = @GeoLinks
    BEGIN
        SET @Score = 3;
        SET @Finding = N'Azure SQL Database [' + @DatabaseQueried + N']: ' + CAST(@GeoLinks AS NVARCHAR(10)) + N' geo-replication link(s) configured, all in CATCH_UP state - ' + @GeoDetail + N'.';
    END
    ELSE IF (@GeoCatchUp + @GeoSeeding) = @GeoLinks
    BEGIN
        SET @Score = 2;
        SET @Finding = N'Azure SQL Database [' + @DatabaseQueried + N']: ' + CAST(@GeoLinks AS NVARCHAR(10)) + N' geo-replication link(s) configured, ' + CAST(@GeoSeeding AS NVARCHAR(10)) + N' still seeding - ' + @GeoDetail + N'.';
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Finding = N'Azure SQL Database [' + @DatabaseQueried + N']: ' + CAST(@GeoLinks AS NVARCHAR(10)) + N' geo-replication link(s) configured but only ' + CAST(@GeoCatchUp AS NVARCHAR(10)) + N' in CATCH_UP state - ' + @GeoDetail + N'.';
    END
END
ELSE
BEGIN
    SET @DatabaseQueried = N'master';

    IF OBJECT_ID(N'sys.availability_replicas') IS NOT NULL
    BEGIN
        SET @sql = N'SELECT @async = ISNULL(SUM(CASE WHEN ar.availability_mode = 0 THEN 1 ELSE 0 END), 0),
       @sync = ISNULL(SUM(CASE WHEN ar.availability_mode = 1 THEN 1 ELSE 0 END), 0),
       @unhealthy = ISNULL(SUM(CASE WHEN ISNULL(rs.synchronization_health, 0) <> 2 OR ISNULL(rs.connected_state, 0) <> 1 THEN 1 ELSE 0 END), 0),
       @dist = ISNULL(SUM(CASE WHEN ag.is_distributed = 1 THEN 1 ELSE 0 END), 0),
       @detail = ISNULL(STUFF((SELECT '', '' + ag2.name + '' -> '' + ar2.replica_server_name + '' ('' + ISNULL(ar2.availability_mode_desc, ''UNKNOWN'') + '')''
                               FROM sys.availability_replicas AS ar2
                               INNER JOIN sys.availability_groups AS ag2 ON ag2.group_id = ar2.group_id
                               WHERE ar2.replica_server_name <> CAST(SERVERPROPERTY(''ServerName'') AS NVARCHAR(256))
                               FOR XML PATH(''''), TYPE).value(''.'', ''nvarchar(max)''), 1, 2, ''''), ''none'')
FROM sys.availability_replicas AS ar
INNER JOIN sys.availability_groups AS ag ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states AS rs ON rs.replica_id = ar.replica_id
WHERE ar.replica_server_name <> CAST(SERVERPROPERTY(''ServerName'') AS NVARCHAR(256));';

        EXEC sys.sp_executesql @sql,
             N'@async INT OUTPUT, @sync INT OUTPUT, @unhealthy INT OUTPUT, @dist INT OUTPUT, @detail NVARCHAR(2000) OUTPUT',
             @async = @AsyncReplicas OUTPUT, @sync = @SyncReplicas OUTPUT, @unhealthy = @UnhealthyReplicas OUTPUT,
             @dist = @DistributedReplicas OUTPUT, @detail = @AgDetail OUTPUT;
    END

    IF OBJECT_ID(N'msdb.dbo.log_shipping_primary_databases') IS NOT NULL
    BEGIN
        SET @sql = N'SELECT @ls = COUNT(*) FROM msdb.dbo.log_shipping_primary_databases;';
        EXEC sys.sp_executesql @sql, N'@ls INT OUTPUT', @ls = @LogShipDbs OUTPUT;
    END

    SET @AsyncReplicas = ISNULL(@AsyncReplicas, 0);
    SET @SyncReplicas = ISNULL(@SyncReplicas, 0);
    SET @UnhealthyReplicas = ISNULL(@UnhealthyReplicas, 0);
    SET @DistributedReplicas = ISNULL(@DistributedReplicas, 0);
    SET @LogShipDbs = ISNULL(@LogShipDbs, 0);
    SET @AgDetail = ISNULL(@AgDetail, N'none');

    IF @DistributedReplicas > 0 OR @AsyncReplicas > 0
    BEGIN
        IF @UnhealthyReplicas = 0
            SET @Score = 3;
        ELSE
            SET @Score = 1;

        SET @Finding = N'DR-tier replication detected: ' + CAST(@AsyncReplicas AS NVARCHAR(10)) + N' asynchronous-commit remote replica(s), '
                     + CAST(@DistributedReplicas AS NVARCHAR(10)) + N' distributed availability group replica(s), '
                     + CAST(@LogShipDbs AS NVARCHAR(10)) + N' log-shipped database(s); remote replicas not healthy/connected: '
                     + CAST(@UnhealthyReplicas AS NVARCHAR(10)) + N'. Remote replicas - ' + @AgDetail + N'.';
    END
    ELSE IF @LogShipDbs > 0
    BEGIN
        SET @Score = 2;
        SET @Finding = N'No availability group DR replica is present; the only remote replication is log shipping covering ' + CAST(@LogShipDbs AS NVARCHAR(10)) + N' database(s). Synchronous-commit remote replicas: ' + CAST(@SyncReplicas AS NVARCHAR(10)) + N'.';
    END
    ELSE IF @SyncReplicas > 0
    BEGIN
        SET @Score = 1;
        SET @Finding = N'Only local high-availability replication is configured: ' + CAST(@SyncReplicas AS NVARCHAR(10)) + N' synchronous-commit remote replica(s) and no asynchronous-commit, distributed availability group or log-shipping DR tier. Remote replicas - ' + @AgDetail + N'.';
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = N'No geo-replication, failover group, availability group secondary or log shipping is configured on this instance, so no DR replication exists. Confirm whether DR is required for the hosted databases.';
    END
END

SET @Score = ISNULL(@Score, 0);
SET @DatabaseQueried = ISNULL(@DatabaseQueried, N'No database found to be queried');
SET @Finding = ISNULL(@Finding, N'Unable to determine the disaster-recovery replication configuration.');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;