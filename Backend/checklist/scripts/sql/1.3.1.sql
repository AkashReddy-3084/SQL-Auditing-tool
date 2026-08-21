/* Checklist 1.3.1 - HA approach defined and matches SLA.
   Read-only detection of the configured HA/DR topology for the connected instance. */
SET NOCOUNT ON;

DECLARE @EngineEdition     INT            = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @DatabaseQueried   NVARCHAR(256)  = ISNULL(CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(256)), N'SERVER');
DECLARE @Result            NVARCHAR(50);
DECLARE @Score             INT            = 1;
DECLARE @Finding           NVARCHAR(4000) = N'';
DECLARE @IsHadrEnabled     INT            = ISNULL(CAST(SERVERPROPERTY('IsHadrEnabled') AS INT), 0);
DECLARE @IsClustered       INT            = ISNULL(CAST(SERVERPROPERTY('IsClustered') AS INT), 0);
DECLARE @AGCount           INT            = 0;
DECLARE @AGWithSecondary   INT            = 0;
DECLARE @AGDetail          NVARCHAR(2000) = N'';
DECLARE @MirroredDbCount   INT            = 0;
DECLARE @LogShippedDbCount INT            = 0;
DECLARE @GeoLinkCount      INT            = 0;
DECLARE @GeoDetail         NVARCHAR(2000) = N'';
DECLARE @ServiceObjective  NVARCHAR(128)  = N'';
DECLARE @Sql               NVARCHAR(MAX);

IF @EngineEdition IN (5, 6, 9, 11)
BEGIN
    /* Azure SQL Database / Synapse: instance-level Always On metadata is not exposed. */
    SET @DatabaseQueried  = DB_NAME();
    SET @ServiceObjective = ISNULL(CAST(DATABASEPROPERTYEX(DB_NAME(), 'ServiceObjective') AS NVARCHAR(128)), N'Unknown');

    IF OBJECT_ID('sys.dm_geo_replication_link_status') IS NOT NULL
    BEGIN
        BEGIN TRY
            SET @Sql = N'SELECT @cnt = COUNT(*) FROM sys.dm_geo_replication_link_status;';
            EXEC sp_executesql @Sql, N'@cnt INT OUTPUT', @cnt = @GeoLinkCount OUTPUT;
        END TRY
        BEGIN CATCH
            SET @GeoLinkCount = 0;
        END CATCH

        IF @GeoLinkCount > 0
        BEGIN
            BEGIN TRY
                SET @Sql = N'SELECT @det = STUFF((SELECT N'', '' + ISNULL(partner_server, N''(unknown)'') + N''.''
                                                       + ISNULL(partner_database, N''(unknown)'')
                                                       + N'' ['' + ISNULL(role_desc, N''?'') + N'']''
                                                  FROM sys.dm_geo_replication_link_status
                                                  FOR XML PATH(N''''), TYPE).value(N''.'', N''nvarchar(2000)''), 1, 2, N'''');';
                EXEC sp_executesql @Sql, N'@det NVARCHAR(2000) OUTPUT', @det = @GeoDetail OUTPUT;
            END TRY
            BEGIN CATCH
                SET @GeoDetail = N'(link detail unavailable)';
            END CATCH
        END
    END

    IF @GeoLinkCount > 0
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'Azure SQL Database [' + @DatabaseQueried + N'] (service objective: ' + @ServiceObjective
                     + N') is protected by ' + CAST(@GeoLinkCount AS NVARCHAR(10))
                     + N' active geo-replication / failover-group link(s): ' + ISNULL(@GeoDetail, N'(none listed)')
                     + N'. A regional HA/DR approach is defined; confirm the resulting RTO/RPO matches the documented SLA.';
    END
    ELSE IF @ServiceObjective LIKE N'BC[_]%' OR @ServiceObjective LIKE N'P[0-9]%' OR @ServiceObjective LIKE N'%Premium%'
    BEGIN
        SET @Score   = 2;
        SET @Finding = N'Azure SQL Database [' + @DatabaseQueried + N'] runs on service objective ' + @ServiceObjective
                     + N', which provides built-in local (and optionally zone-redundant) replicas, but no geo-replication or '
                     + N'failover-group link is configured. Regional failover capability is not defined; verify the SLA and '
                     + N'zone-redundancy setting (not exposed through T-SQL) in the Azure portal.';
    END
    ELSE
    BEGIN
        SET @Score   = 1;
        SET @Finding = N'Azure SQL Database [' + @DatabaseQueried + N'] runs on service objective ' + @ServiceObjective
                     + N' with no geo-replication or failover-group link configured. Only the default single-region '
                     + N'built-in availability applies, so no explicit HA approach is defined to match an SLA.';
    END
END
ELSE
BEGIN
    /* SQL Server (on-premises / IaaS) and Azure SQL Managed Instance. */
    IF OBJECT_ID('sys.availability_groups') IS NOT NULL
    BEGIN
        BEGIN TRY
            SET @Sql = N'SELECT @cnt = COUNT(*) FROM sys.availability_groups;';
            EXEC sp_executesql @Sql, N'@cnt INT OUTPUT', @cnt = @AGCount OUTPUT;

            IF @AGCount > 0
            BEGIN
                SET @Sql = N'SELECT @cnt = COUNT(*) FROM (SELECT group_id FROM sys.availability_replicas
                             GROUP BY group_id HAVING COUNT(*) > 1) AS q;';
                EXEC sp_executesql @Sql, N'@cnt INT OUTPUT', @cnt = @AGWithSecondary OUTPUT;

                SET @Sql = N'SELECT @det = STUFF((SELECT N'', '' + ag.name + N'' ('' + CAST(x.replica_count AS NVARCHAR(10))
                                     + N'' replica(s), '' + CAST(x.auto_failover_count AS NVARCHAR(10)) + N'' automatic-failover)''
                             FROM sys.availability_groups AS ag
                             CROSS APPLY (SELECT COUNT(*) AS replica_count,
                                                 SUM(CASE WHEN ar.failover_mode_desc = N''AUTOMATIC'' THEN 1 ELSE 0 END) AS auto_failover_count
                                          FROM sys.availability_replicas AS ar
                                          WHERE ar.group_id = ag.group_id) AS x
                             ORDER BY ag.name
                             FOR XML PATH(N''''), TYPE).value(N''.'', N''nvarchar(2000)''), 1, 2, N'''');';
                EXEC sp_executesql @Sql, N'@det NVARCHAR(2000) OUTPUT', @det = @AGDetail OUTPUT;
            END
        END TRY
        BEGIN CATCH
            SET @AGDetail = N'(availability group detail unavailable: ' + ERROR_MESSAGE() + N')';
        END CATCH
    END

    IF OBJECT_ID('sys.database_mirroring') IS NOT NULL
    BEGIN
        BEGIN TRY
            SET @Sql = N'SELECT @cnt = COUNT(*) FROM sys.database_mirroring WHERE mirroring_guid IS NOT NULL;';
            EXEC sp_executesql @Sql, N'@cnt INT OUTPUT', @cnt = @MirroredDbCount OUTPUT;
        END TRY
        BEGIN CATCH
            SET @MirroredDbCount = 0;
        END CATCH
    END

    IF @EngineEdition <> 8 AND OBJECT_ID('msdb.dbo.log_shipping_primary_databases') IS NOT NULL
    BEGIN
        BEGIN TRY
            SET @Sql = N'SELECT @cnt = COUNT(*) FROM msdb.dbo.log_shipping_primary_databases;';
            EXEC sp_executesql @Sql, N'@cnt INT OUTPUT', @cnt = @LogShippedDbCount OUTPUT;
        END TRY
        BEGIN CATCH
            SET @LogShippedDbCount = 0;
        END CATCH
    END

    IF @AGCount > 0 AND @AGWithSecondary > 0
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'Instance [' + @DatabaseQueried + N'] has ' + CAST(@AGCount AS NVARCHAR(10))
                     + N' Always On availability group(s), ' + CAST(@AGWithSecondary AS NVARCHAR(10))
                     + N' of which have more than one replica: ' + ISNULL(NULLIF(@AGDetail, N''), N'(names unavailable)')
                     + N'. IsClustered=' + CAST(@IsClustered AS NVARCHAR(2)) + N'. An HA approach is defined; confirm the '
                     + N'replica placement and failover mode deliver the RTO/RPO stated in the documented SLA.';
    END
    ELSE IF @IsClustered = 1
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'Instance [' + @DatabaseQueried + N'] is a failover cluster instance (SERVERPROPERTY IsClustered = 1) '
                     + N'with ' + CAST(@AGCount AS NVARCHAR(10)) + N' availability group(s) defined. An HA approach is in place; '
                     + N'confirm the cluster node/quorum design meets the documented SLA.';
    END
    ELSE IF @AGCount > 0
    BEGIN
        SET @Score   = 2;
        SET @Finding = N'Instance [' + @DatabaseQueried + N'] has ' + CAST(@AGCount AS NVARCHAR(10))
                     + N' availability group(s) but none with more than one replica: '
                     + ISNULL(NULLIF(@AGDetail, N''), N'(names unavailable)')
                     + N'. A single-replica availability group provides no failover target, so the HA approach is incomplete.';
    END
    ELSE IF @IsHadrEnabled = 1
    BEGIN
        SET @Score   = 2;
        SET @Finding = N'Instance [' + @DatabaseQueried + N'] has the Always On availability groups feature enabled '
                     + N'(SERVERPROPERTY IsHadrEnabled = 1) but no availability group is defined, and it is not clustered. '
                     + N'Mirrored databases: ' + CAST(@MirroredDbCount AS NVARCHAR(10))
                     + N'; log-shipped databases: ' + CAST(@LogShippedDbCount AS NVARCHAR(10))
                     + N'. HA is prepared but not implemented.';
    END
    ELSE IF @MirroredDbCount > 0 OR @LogShippedDbCount > 0
    BEGIN
        SET @Score   = 2;
        SET @Finding = N'Instance [' + @DatabaseQueried + N'] has no availability group and is not clustered; protection relies on '
                     + CAST(@MirroredDbCount AS NVARCHAR(10)) + N' mirrored database(s) and '
                     + CAST(@LogShippedDbCount AS NVARCHAR(10)) + N' log-shipped database(s). These are deprecated / '
                     + N'DR-oriented mechanisms with manual or partial failover, so the HA approach may not meet the documented SLA.';
    END
    ELSE
    BEGIN
        SET @Score   = 1;
        SET @Finding = N'Instance [' + @DatabaseQueried + N'] is standalone: IsHadrEnabled=0, IsClustered=0, no availability groups, '
                     + N'no mirrored databases and no log-shipped databases. No high-availability approach is defined, so no SLA '
                     + N'beyond restore-from-backup can be met.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;