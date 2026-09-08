-- Checklist: HA solution matches SLA (Always On AG / failover groups / zone redundancy)
-- Scope: SERVER
-- Scoring: 3 = an availability group with 2 or more replicas including at least two synchronous-commit replicas, or an Azure database that is zone redundant or geo-replicated; 2 = a failover cluster with 2 or more nodes, an availability group with 2 replicas but only one synchronous-commit replica, or Azure platform-local HA on existing databases; 1 = an availability group or cluster object exists with a single member, or no user database is present; 0 = no HA mechanism detected

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'High availability evidence could not be collected from this instance';
DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Groups INT = 0;
DECLARE @Replicas INT = 0;
DECLARE @SyncReplicas INT = 0;
DECLARE @Nodes INT = 0;
DECLARE @ZoneRedundant INT = 0;
DECLARE @GeoLinks INT = 0;
DECLARE @Databases INT = 0;
DECLARE @Names NVARCHAR(400) = 'none';
DECLARE @Note NVARCHAR(300) = '';

IF @Edition = 5
BEGIN
    SELECT @Databases = COUNT(*) FROM sys.databases WHERE database_id > 4;

    BEGIN TRY
        IF COL_LENGTH('sys.databases', 'is_zone_redundant') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT @z = COUNT(*) FROM sys.databases WHERE database_id > 4 AND is_zone_redundant = 1;';
            EXEC sp_executesql @Sql, N'@z INT OUTPUT', @z = @ZoneRedundant OUTPUT;
        END

        IF OBJECT_ID('sys.geo_replication_links') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT @g = COUNT(*) FROM sys.geo_replication_links;';
            EXEC sp_executesql @Sql, N'@g INT OUTPUT', @g = @GeoLinks OUTPUT;
        END
    END TRY
    BEGIN CATCH
        SET @Note = ' Some Azure HA metadata was not readable.';
    END CATCH

    SET @ZoneRedundant = ISNULL(@ZoneRedundant, 0);
    SET @GeoLinks = ISNULL(@GeoLinks, 0);
    SET @Databases = ISNULL(@Databases, 0);

    SET @Score = CASE
        WHEN @ZoneRedundant > 0 OR @GeoLinks > 0 THEN 3
        WHEN @Databases > 0 THEN 2
        ELSE 1 END;

    SET @Finding = CONCAT('Azure SQL Database: user databases = ', @Databases,
        ', zone-redundant databases = ', @ZoneRedundant,
        ', geo-replication links = ', @GeoLinks,
        '. Local replica redundancy is provided by the platform.', @Note);
END
ELSE
BEGIN
    BEGIN TRY
        IF OBJECT_ID('sys.availability_replicas') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT @a = (SELECT COUNT(*) FROM sys.availability_groups),
       @r = (SELECT COUNT(*) FROM sys.availability_replicas),
       @s = (SELECT COUNT(*) FROM sys.availability_replicas WHERE availability_mode_desc = ''SYNCHRONOUS_COMMIT''),
       @m = ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(200), ag.name), '', '') FROM sys.availability_groups AS ag), ''none'');';
            EXEC sp_executesql @Sql,
                 N'@a INT OUTPUT, @r INT OUTPUT, @s INT OUTPUT, @m NVARCHAR(400) OUTPUT',
                 @a = @Groups OUTPUT, @r = @Replicas OUTPUT, @s = @SyncReplicas OUTPUT, @m = @Names OUTPUT;
        END
    END TRY
    BEGIN CATCH
        SET @Note = ' Always On availability metadata was not readable.';
    END CATCH

    BEGIN TRY
        IF OBJECT_ID('sys.dm_os_cluster_nodes') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT @n = COUNT(*) FROM sys.dm_os_cluster_nodes;';
            EXEC sp_executesql @Sql, N'@n INT OUTPUT', @n = @Nodes OUTPUT;
        END
    END TRY
    BEGIN CATCH
        SET @Note = @Note + ' Windows failover cluster node list was not readable.';
    END CATCH

    SET @Groups = ISNULL(@Groups, 0);
    SET @Replicas = ISNULL(@Replicas, 0);
    SET @SyncReplicas = ISNULL(@SyncReplicas, 0);
    SET @Nodes = ISNULL(@Nodes, 0);
    SET @Names = ISNULL(@Names, 'none');

    SET @Score = CASE
        WHEN @Groups > 0 AND @Replicas >= 2 AND @SyncReplicas >= 2 THEN 3
        WHEN @Groups > 0 AND @Replicas >= 2 THEN 2
        WHEN @Nodes >= 2 THEN 2
        WHEN @Groups > 0 OR @Nodes = 1 THEN 1
        ELSE 0 END;

    SET @Finding = CONCAT('Availability groups = ', @Groups, ' (', @Names,
        '), replicas = ', @Replicas,
        ', synchronous-commit replicas = ', @SyncReplicas,
        ', failover cluster nodes = ', @Nodes, '.',
        CASE WHEN @Groups = 0 AND @Nodes < 2
             THEN ' No availability group and no multi-node failover cluster is configured, so this instance is a single point of failure.'
             ELSE '' END,
        @Note);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
