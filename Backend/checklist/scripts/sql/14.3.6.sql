/*
    Checklist Item : 14.3.6 - Reporting workloads isolated from write workloads (read replicas) where possible
    Scope          : SERVER
    Access         : Read-only. No DDL, no DML, no configuration change.
    Output         : Result, Score, DatabaseQueried, Finding
*/
SET NOCOUNT ON;

DECLARE @EngineEdition        int           = CAST(SERVERPROPERTY('EngineEdition') AS int);
DECLARE @IsAzureSqlDb         bit           = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) IN (5, 6, 11) THEN 1 ELSE 0 END;
DECLARE @DatabaseQueried      nvarchar(256);
DECLARE @Result               nvarchar(20);
DECLARE @Score                int = 0;
DECLARE @Finding              nvarchar(4000);

DECLARE @HadrReplicas         int = 0;
DECLARE @ReadableSecondaries  int = 0;
DECLARE @RoutingLists         int = 0;
DECLARE @GeoReplicas          int = 0;
DECLARE @ReplicationDbs       int = 0;
DECLARE @LogShippingPrimary   int = 0;
DECLARE @LogShippingSecondary int = 0;
DECLARE @ReadScaleTier        bit = 0;
DECLARE @ServiceObjective     nvarchar(128) = NULL;
DECLARE @sql                  nvarchar(max);

SET @DatabaseQueried = CASE WHEN @IsAzureSqlDb = 1 THEN DB_NAME() ELSE N'master' END;

IF @IsAzureSqlDb = 1
BEGIN
    /* Azure SQL Database: read scale-out is inherent to Premium / Business Critical / Hyperscale, geo-replicas are readable. */
    SET @ServiceObjective = CAST(DATABASEPROPERTYEX(DB_NAME(), 'ServiceObjective') AS nvarchar(128));

    IF @ServiceObjective LIKE N'P[0-9]%'
        OR @ServiceObjective LIKE N'PRS%'
        OR @ServiceObjective LIKE N'BC[_]%'
        OR @ServiceObjective LIKE N'HS[_]%'
        SET @ReadScaleTier = 1;

    IF EXISTS (SELECT 1 FROM sys.all_objects WHERE schema_id = SCHEMA_ID('sys') AND name = 'dm_geo_replication_link_status')
    BEGIN
        SET @sql = N'SELECT @cnt = COUNT(*) FROM sys.dm_geo_replication_link_status;';
        BEGIN TRY
            EXEC sp_executesql @sql, N'@cnt int OUTPUT', @cnt = @GeoReplicas OUTPUT;
        END TRY
        BEGIN CATCH
            SET @GeoReplicas = 0;
        END CATCH
    END
END
ELSE
BEGIN
    /* SQL Server / Azure SQL Managed Instance: Always On readable secondaries and read-only routing. */
    IF EXISTS (SELECT 1 FROM sys.all_objects WHERE schema_id = SCHEMA_ID('sys') AND name = 'availability_replicas')
    BEGIN
        SET @sql = N'
            SELECT @tot = ISNULL(COUNT(*), 0),
                   @ro  = ISNULL(SUM(CASE WHEN ar.secondary_role_allow_connections IN (1, 2) THEN 1 ELSE 0 END), 0)
            FROM sys.availability_replicas AS ar;';
        BEGIN TRY
            EXEC sp_executesql @sql, N'@tot int OUTPUT, @ro int OUTPUT',
                 @tot = @HadrReplicas OUTPUT, @ro = @ReadableSecondaries OUTPUT;
        END TRY
        BEGIN CATCH
            SET @HadrReplicas = 0;
            SET @ReadableSecondaries = 0;
        END CATCH
    END

    IF EXISTS (SELECT 1 FROM sys.all_objects WHERE schema_id = SCHEMA_ID('sys') AND name = 'availability_read_only_routing_lists')
    BEGIN
        SET @sql = N'SELECT @cnt = ISNULL(COUNT(*), 0) FROM sys.availability_read_only_routing_lists;';
        BEGIN TRY
            EXEC sp_executesql @sql, N'@cnt int OUTPUT', @cnt = @RoutingLists OUTPUT;
        END TRY
        BEGIN CATCH
            SET @RoutingLists = 0;
        END CATCH
    END

    /* Replication subscribers / publishers are a classic reporting offload target. */
    BEGIN TRY
        SELECT @ReplicationDbs = COUNT(*)
        FROM sys.databases AS d
        WHERE d.state = 0
          AND (d.is_published = 1 OR d.is_merge_published = 1 OR d.is_subscribed = 1);
    END TRY
    BEGIN CATCH
        SET @ReplicationDbs = 0;
    END CATCH

    /* Log-shipped standby databases can also serve read-only reporting. */
    IF OBJECT_ID('msdb.dbo.log_shipping_primary_databases', 'U') IS NOT NULL
    BEGIN
        SET @sql = N'SELECT @cnt = ISNULL(COUNT(*), 0) FROM msdb.dbo.log_shipping_primary_databases;';
        BEGIN TRY
            EXEC sp_executesql @sql, N'@cnt int OUTPUT', @cnt = @LogShippingPrimary OUTPUT;
        END TRY
        BEGIN CATCH
            SET @LogShippingPrimary = 0;
        END CATCH
    END

    IF OBJECT_ID('msdb.dbo.log_shipping_secondary_databases', 'U') IS NOT NULL
    BEGIN
        SET @sql = N'SELECT @cnt = ISNULL(COUNT(*), 0) FROM msdb.dbo.log_shipping_secondary_databases;';
        BEGIN TRY
            EXEC sp_executesql @sql, N'@cnt int OUTPUT', @cnt = @LogShippingSecondary OUTPUT;
        END TRY
        BEGIN CATCH
            SET @LogShippingSecondary = 0;
        END CATCH
    END
END

IF @IsAzureSqlDb = 1
BEGIN
    SET @Score = CASE WHEN @GeoReplicas > 0 OR @ReadScaleTier = 1 THEN 3 ELSE 0 END;

    SET @Finding = CONCAT(
        N'Azure SQL Database "', DB_NAME(), N'" (EngineEdition ', @EngineEdition,
        N', service objective ', ISNULL(@ServiceObjective, N'unknown'), N'). Geo-replication links: ', @GeoReplicas,
        N'. Read scale-out capable tier: ', CASE WHEN @ReadScaleTier = 1 THEN N'YES' ELSE N'NO' END, N'. ',
        CASE
            WHEN @GeoReplicas > 0 OR @ReadScaleTier = 1
                THEN N'A readable replica is available, so reporting traffic can be routed away from the read-write primary using ApplicationIntent=ReadOnly.'
            ELSE N'No readable replica is available on this tier, so reporting queries contend with the write workload on the primary.'
        END);
END
ELSE
BEGIN
    SET @Score = CASE
                     WHEN @ReadableSecondaries > 0 AND @RoutingLists > 0 THEN 3
                     WHEN @ReadableSecondaries > 0 THEN 2
                     WHEN @ReplicationDbs > 0 OR @LogShippingPrimary > 0 OR @LogShippingSecondary > 0 THEN 2
                     WHEN @HadrReplicas > 0 THEN 1
                     ELSE 0
                 END;

    SET @Finding = CONCAT(
        N'Instance "', CONVERT(nvarchar(128), SERVERPROPERTY('ServerName')), N'" (EngineEdition ', @EngineEdition,
        N'). Availability replicas: ', @HadrReplicas,
        N'; replicas allowing read-intent connections in secondary role: ', @ReadableSecondaries,
        N'; read-only routing list entries: ', @RoutingLists,
        N'; databases involved in replication: ', @ReplicationDbs,
        N'; log shipping primary databases: ', @LogShippingPrimary,
        N'; log shipping secondary databases: ', @LogShippingSecondary, N'. ',
        CASE
            WHEN @ReadableSecondaries > 0 AND @RoutingLists > 0
                THEN N'Readable secondaries are configured and read-only routing is defined, so ApplicationIntent=ReadOnly reporting sessions are directed to a replica instead of the write primary.'
            WHEN @ReadableSecondaries > 0
                THEN N'Readable secondaries exist but no read-only routing list is defined; reporting clients are only offloaded if they connect to the secondary directly. Confirm how reporting connections are routed.'
            WHEN @ReplicationDbs > 0 OR @LogShippingPrimary > 0 OR @LogShippingSecondary > 0
                THEN N'No readable Always On secondary is configured, but replication and/or log shipping is in use and may serve as the reporting copy. Confirm that reporting queries target that copy rather than the primary.'
            WHEN @HadrReplicas > 0
                THEN N'Availability replicas exist but none accept read-intent connections in the secondary role, so all reporting queries run against the read-write primary.'
            ELSE N'No readable secondary, replication subscriber or log-shipped standby was found; reporting and write workloads share the same instance.'
        END);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;