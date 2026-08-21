SET NOCOUNT ON;

DECLARE @Result           NVARCHAR(20);
DECLARE @Score            INT            = 1;
DECLARE @Finding          NVARCHAR(4000) = N'';
DECLARE @DatabaseQueried  NVARCHAR(128)  = N'master';

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @IsClustered   INT = CAST(ISNULL(SERVERPROPERTY('IsClustered'), 0) AS INT);
DECLARE @IsHadrEnabled INT = CAST(ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0) AS INT);
DECLARE @ServerName    NVARCHAR(256) = CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(256));

DECLARE @AGCount               INT = 0;
DECLARE @ReplicaCount          INT = 0;
DECLARE @LocalIsPrimary        INT = 0;
DECLARE @UnhealthyReplicas     INT = 0;
DECLARE @ReplicasMissingDbs    INT = 0;
DECLARE @TimeoutMismatchAGs    INT = 0;
DECLARE @FailoverConfigIssues  INT = 0;
DECLARE @CollectionError       NVARCHAR(2000) = NULL;
DECLARE @Detail                NVARCHAR(2000) = N'';
DECLARE @sql                   NVARCHAR(MAX);

IF @EngineEdition = 5
BEGIN
    /* Azure SQL Database: no user-visible nodes, replica configuration is service-managed. */
    SET @DatabaseQueried = DB_NAME();
    SET @Score   = 3;
    SET @Finding = N'Azure SQL Database detected (EngineEdition 5). High availability replicas are provisioned and configured by the platform from a single service objective, so node configuration parity (instance settings, memory/DOP limits, logins, jobs, linked servers, certificates) is enforced by the service and cannot diverge.';
END
ELSE
BEGIN
    BEGIN TRY
        IF OBJECT_ID('sys.availability_groups') IS NOT NULL
        BEGIN
            SET @sql = N'SELECT @c = COUNT(*) FROM sys.availability_groups;';
            EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @AGCount OUTPUT;
        END;

        IF @AGCount > 0
        BEGIN
            SET @sql = N'SELECT @c = COUNT(*) FROM sys.availability_replicas;';
            EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @ReplicaCount OUTPUT;

            SET @sql = N'SELECT @c = COUNT(*)
                         FROM sys.dm_hadr_availability_replica_states
                         WHERE is_local = 1 AND role = 1;';
            EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @LocalIsPrimary OUTPUT;

            /* Replica-level settings are cluster-wide metadata: readable from any replica. */
            SET @sql = N'SELECT @c = COUNT(*)
                         FROM (
                             SELECT ar.group_id
                             FROM sys.availability_replicas AS ar
                             GROUP BY ar.group_id
                             HAVING COUNT(DISTINCT ar.session_timeout) > 1
                         ) AS x;';
            EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @TimeoutMismatchAGs OUTPUT;

            SET @sql = N'SELECT @c = COUNT(*)
                         FROM sys.availability_replicas AS ar
                         WHERE ar.failover_mode = 1
                           AND ar.availability_mode <> 1;';
            EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @FailoverConfigIssues OUTPUT;

            IF @LocalIsPrimary > 0
            BEGIN
                /* Connection and synchronization state for every replica is only complete on the primary. */
                SET @sql = N'SELECT @c = COUNT(*)
                             FROM sys.dm_hadr_availability_replica_states
                             WHERE connected_state <> 1
                                OR synchronization_health <> 2;';
                EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @UnhealthyReplicas OUTPUT;

                /* A replica hosting fewer databases than the AG defines is a parity gap. */
                SET @sql = N'SELECT @c = COUNT(*)
                             FROM sys.availability_replicas AS ar
                             CROSS APPLY (
                                 SELECT COUNT(*) AS ExpectedDbs
                                 FROM sys.availability_databases_cluster AS adc
                                 WHERE adc.group_id = ar.group_id
                             ) AS e
                             CROSS APPLY (
                                 SELECT COUNT(DISTINCT drs.group_database_id) AS ActualDbs
                                 FROM sys.dm_hadr_database_replica_states AS drs
                                 WHERE drs.replica_id = ar.replica_id
                             ) AS a
                             WHERE a.ActualDbs < e.ExpectedDbs;';
                EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @ReplicasMissingDbs OUTPUT;
            END;
        END;
    END TRY
    BEGIN CATCH
        SET @CollectionError = ERROR_MESSAGE();
    END CATCH;

    IF @CollectionError IS NOT NULL
    BEGIN
        SET @Score   = 1;
        SET @Finding = N'HA topology metadata could not be read on ' + @ServerName
                     + N'. VIEW SERVER STATE (and access to the HADR catalog views) is required to compare node configuration. Error: '
                     + ISNULL(@CollectionError, N'(unknown)')
                     + N'. Node configuration parity cannot be evidenced; re-run the check with sufficient permissions.';
    END
    ELSE IF @AGCount = 0 AND @IsClustered = 1
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'Instance ' + @ServerName
                     + N' is a Failover Cluster Instance (SERVERPROPERTY(''IsClustered'') = 1) with no Availability Groups configured. All cluster nodes run the single shared instance from shared storage, so instance configuration, trace flags, MAXDOP/memory settings, logins, SQL Agent jobs, linked servers and certificates are the same objects on every node and cannot diverge.';
    END
    ELSE IF @AGCount = 0
    BEGIN
        SET @Score   = 1;
        SET @Finding = N'No HA topology detected on ' + @ServerName
                     + N': SERVERPROPERTY(''IsClustered'') = 0, IsHadrEnabled = ' + CAST(@IsHadrEnabled AS NVARCHAR(10))
                     + N' and 0 Availability Groups exist, so there is no partner node whose configuration can be compared and no node configuration parity has been established.';
    END
    ELSE
    BEGIN
        SET @Detail = N'AGs: ' + CAST(@AGCount AS NVARCHAR(10))
                    + N'; replicas: ' + CAST(@ReplicaCount AS NVARCHAR(10))
                    + N'; unhealthy or disconnected replicas: ' + CAST(@UnhealthyReplicas AS NVARCHAR(10))
                    + N'; replicas missing AG databases: ' + CAST(@ReplicasMissingDbs AS NVARCHAR(10))
                    + N'; AGs with non-uniform session_timeout: ' + CAST(@TimeoutMismatchAGs AS NVARCHAR(10))
                    + N'; automatic-failover replicas not on synchronous commit: ' + CAST(@FailoverConfigIssues AS NVARCHAR(10))
                    + N'.';

        IF @UnhealthyReplicas > 0 OR @ReplicasMissingDbs > 0 OR @TimeoutMismatchAGs > 0 OR @FailoverConfigIssues > 0
        BEGIN
            SET @Score   = 1;
            SET @Finding = N'Availability Group replica configuration is not in parity on ' + @ServerName + N'. ' + @Detail
                         + N' Divergent replica settings, replicas that are disconnected or unsynchronised, or replicas that do not host every AG database mean the nodes are not interchangeable and a failover would not deliver an equivalent service.';
        END
        ELSE IF @LocalIsPrimary = 0
        BEGIN
            SET @Score   = 2;
            SET @Finding = N'The audited instance ' + @ServerName
                         + N' is a secondary replica, so replica connection state, synchronization health and database-join state are only partially populated here. ' + @Detail
                         + N' Cluster-wide replica settings readable from this node show no divergence. Re-run the check against the primary replica, and compare instance-local settings (trace flags, sp_configure/MAXDOP/max server memory, logins, SQL Agent jobs, linked servers, certificates) by executing the audit on each node.';
        END
        ELSE
        BEGIN
            SET @Score   = 2;
            SET @Finding = N'All Availability Group parity signals observable from this connection are clean on ' + @ServerName + N'. ' + @Detail
                         + N' Instance-local configuration of the remote replicas - trace flags (DBCC TRACESTATUS), sp_configure values such as MAXDOP and max server memory, server logins and their SIDs, SQL Agent jobs, linked servers and certificates - is not exposed by any DMV from a single connection, so run this audit on every replica and compare the results to complete the parity verification.';
        END;
    END;
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;