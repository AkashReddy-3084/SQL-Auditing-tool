/*
    Checklist Item : 1.3.3 - Read-scale replicas used for reporting where appropriate
    Scope          : SERVER (instance-wide)
    Type           : Read-only T-SQL. No data, schema or configuration is modified.
    Output         : Result, Score, DatabaseQueried, Finding
*/
SET NOCOUNT ON;

DECLARE @EngineEdition           INT            = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @DatabaseQueried         NVARCHAR(256)  = ISNULL(CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(256)), DB_NAME());
DECLARE @Result                  NVARCHAR(20)   = N'Fail';
DECLARE @Score                   INT            = 0;
DECLARE @Finding                 NVARCHAR(4000) = N'';
DECLARE @sql                     NVARCHAR(MAX);
DECLARE @AGCount                 INT = 0;
DECLARE @ReplicaCount            INT = 0;
DECLARE @ReadableSecondaryCount  INT = 0;
DECLARE @RoutingEntryCount       INT = 0;
DECLARE @RoutingUrlCount         INT = 0;
DECLARE @ReadableList            NVARCHAR(1000) = N'';
DECLARE @PublishedDbCount        INT = 0;
DECLARE @LogShipPrimaryCount     INT = 0;
DECLARE @GeoSecondaryCount       INT = 0;

IF OBJECT_ID('tempdb..#Replicas') IS NOT NULL DROP TABLE #Replicas;
CREATE TABLE #Replicas
(
    AGName                        NVARCHAR(256) NULL,
    ReplicaServerName             NVARCHAR(256) NULL,
    SecondaryRoleAllowConnections TINYINT       NULL,
    ReadOnlyRoutingUrl            NVARCHAR(256) NULL
);

IF OBJECT_ID('tempdb..#Routing') IS NOT NULL DROP TABLE #Routing;
CREATE TABLE #Routing
(
    SourceReplicaId UNIQUEIDENTIFIER NULL,
    RoutingPriority INT              NULL,
    TargetReplicaId UNIQUEIDENTIFIER NULL
);

BEGIN TRY
    IF @EngineEdition = 5
    BEGIN
        /* Azure SQL Database: readable secondaries are surfaced as geo-replication links. */
        IF OBJECT_ID('sys.geo_replication_links') IS NOT NULL
        BEGIN
            SET @sql = N'SELECT @cnt = COUNT(*) FROM sys.geo_replication_links;';
            EXEC sys.sp_executesql @sql, N'@cnt INT OUTPUT', @cnt = @GeoSecondaryCount OUTPUT;
        END
        ELSE IF OBJECT_ID('sys.dm_geo_replication_link_status') IS NOT NULL
        BEGIN
            SET @sql = N'SELECT @cnt = COUNT(*) FROM sys.dm_geo_replication_link_status;';
            EXEC sys.sp_executesql @sql, N'@cnt INT OUTPUT', @cnt = @GeoSecondaryCount OUTPUT;
        END

        IF @GeoSecondaryCount > 0
        BEGIN
            SET @Score   = 3;
            SET @Finding = N'Azure SQL Database: ' + CAST(@GeoSecondaryCount AS NVARCHAR(10))
                         + N' readable geo-replication secondary link(s) are configured. Reporting clients can be directed to a secondary with ApplicationIntent=ReadOnly, keeping analytical load off the primary.';
        END
        ELSE
        BEGIN
            SET @Score   = 1;
            SET @Finding = N'Azure SQL Database: no geo-replication secondary links were detected. The database-level Read Scale-Out setting is not exposed through T-SQL, so confirm in the Azure portal / CLI whether a read-only replica is enabled and whether reporting connections use ApplicationIntent=ReadOnly.';
        END
    END
    ELSE
    BEGIN
        /* SQL Server (on-premises / IaaS) and Azure SQL Managed Instance. */
        IF CAST(ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0) AS INT) = 1
           AND OBJECT_ID('sys.availability_replicas') IS NOT NULL
           AND OBJECT_ID('sys.availability_groups') IS NOT NULL
        BEGIN
            INSERT INTO #Replicas (AGName, ReplicaServerName, SecondaryRoleAllowConnections, ReadOnlyRoutingUrl)
            EXEC sys.sp_executesql N'
                SELECT ag.name,
                       ar.replica_server_name,
                       ar.secondary_role_allow_connections,
                       ar.read_only_routing_url
                FROM sys.availability_replicas AS ar
                INNER JOIN sys.availability_groups AS ag
                    ON ag.group_id = ar.group_id;';

            IF OBJECT_ID('sys.availability_read_only_routing_lists') IS NOT NULL
            BEGIN
                INSERT INTO #Routing (SourceReplicaId, RoutingPriority, TargetReplicaId)
                EXEC sys.sp_executesql N'
                    SELECT rl.replica_id,
                           rl.routing_priority,
                           rl.read_only_replica_id
                    FROM sys.availability_read_only_routing_lists AS rl;';
            END

            SELECT @AGCount      = COUNT(DISTINCT AGName),
                   @ReplicaCount = COUNT(*)
            FROM #Replicas;

            /* secondary_role_allow_connections: 0 = NO, 1 = READ_ONLY (read-intent), 2 = ALL */
            SELECT @ReadableSecondaryCount = COUNT(*)
            FROM #Replicas
            WHERE SecondaryRoleAllowConnections IN (1, 2);

            SELECT @RoutingUrlCount = COUNT(*)
            FROM #Replicas
            WHERE ReadOnlyRoutingUrl IS NOT NULL;

            SELECT @RoutingEntryCount = COUNT(*) FROM #Routing;

            SELECT @ReadableList = STUFF((
                        SELECT TOP (10) N', ' + ISNULL(AGName, N'(unknown AG)') + N'/' + ISNULL(ReplicaServerName, N'(unknown replica)')
                        FROM #Replicas
                        WHERE SecondaryRoleAllowConnections IN (1, 2)
                        ORDER BY AGName, ReplicaServerName
                        FOR XML PATH(''), TYPE).value('.', 'nvarchar(1000)'), 1, 2, N'');
        END

        SELECT @PublishedDbCount = COUNT(*)
        FROM sys.databases
        WHERE is_published = 1
           OR is_merge_published = 1;

        IF OBJECT_ID('msdb.dbo.log_shipping_primary_databases') IS NOT NULL
        BEGIN
            SET @sql = N'SELECT @cnt = COUNT(*) FROM msdb.dbo.log_shipping_primary_databases;';
            EXEC sys.sp_executesql @sql, N'@cnt INT OUTPUT', @cnt = @LogShipPrimaryCount OUTPUT;
        END

        IF @ReadableSecondaryCount > 0 AND @RoutingEntryCount > 0
        BEGIN
            SET @Score   = 3;
            SET @Finding = N'Read-scale is configured: ' + CAST(@ReadableSecondaryCount AS NVARCHAR(10))
                         + N' of ' + CAST(@ReplicaCount AS NVARCHAR(10)) + N' replica(s) across '
                         + CAST(@AGCount AS NVARCHAR(10)) + N' availability group(s) allow connections in the SECONDARY role ('
                         + ISNULL(@ReadableList, N'n/a') + N'), and ' + CAST(@RoutingEntryCount AS NVARCHAR(10))
                         + N' read-only routing list entry/entries are defined, so read-intent reporting connections are routed away from the primary.';
        END
        ELSE IF @ReadableSecondaryCount > 0
        BEGIN
            SET @Score   = 2;
            SET @Finding = N'Readable secondaries exist (' + CAST(@ReadableSecondaryCount AS NVARCHAR(10))
                         + N' replica(s): ' + ISNULL(@ReadableList, N'n/a')
                         + N') but no read-only routing list is configured (read_only_routing_url populated on '
                         + CAST(@RoutingUrlCount AS NVARCHAR(10))
                         + N' replica(s)). Reporting clients must be pointed at a replica by name instead of being routed automatically by ApplicationIntent=ReadOnly.';
        END
        ELSE IF @AGCount > 0
        BEGIN
            SET @Score   = 1;
            SET @Finding = CAST(@AGCount AS NVARCHAR(10)) + N' availability group(s) with '
                         + CAST(@ReplicaCount AS NVARCHAR(10))
                         + N' replica(s) exist, but no replica allows connections in the SECONDARY role (secondary_role_allow_connections = 0 on every replica). The secondaries provide availability only; all reporting runs against the primary.';
        END
        ELSE IF @PublishedDbCount > 0 OR @LogShipPrimaryCount > 0
        BEGIN
            SET @Score   = 1;
            SET @Finding = N'No readable availability-group secondary was found. Alternative read copies exist ('
                         + CAST(@PublishedDbCount AS NVARCHAR(10)) + N' published/replicated database(s), '
                         + CAST(@LogShipPrimaryCount AS NVARCHAR(10))
                         + N' log-shipping primary database(s)) but these do not provide the near-real-time read-scale of a readable secondary with read-only routing.';
        END
        ELSE
        BEGIN
            SET @Score   = 0;
            SET @Finding = N'No read-scale mechanism was found on this instance: HADR/availability groups '
                         + CASE WHEN CAST(ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0) AS INT) = 1 THEN N'are enabled but no availability group is defined' ELSE N'are not enabled' END
                         + N', and no published (replication) or log-shipping primary databases exist. All reporting workload therefore competes with OLTP activity on the primary.';
        END
    END
END TRY
BEGIN CATCH
    SET @Score   = 1;
    SET @Finding = N'Unable to evaluate read-scale replica configuration (error ' + CAST(ERROR_NUMBER() AS NVARCHAR(10))
                 + N'): ' + ERROR_MESSAGE()
                 + N' Re-run with VIEW SERVER STATE and VIEW ANY DEFINITION permissions.';
END CATCH

IF OBJECT_ID('tempdb..#Replicas') IS NOT NULL DROP TABLE #Replicas;
IF OBJECT_ID('tempdb..#Routing') IS NOT NULL DROP TABLE #Routing;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;