-- Checklist: Secondary region/replica capacity provisioned or evaluated
-- Scope: SERVER
-- Scoring: 3 = at least one secondary replica exists, all secondaries report HEALTHY, and they are readable or automatically seeded (Azure: a geo-secondary exists); 2 = at least one secondary replica or zone-redundant database is provisioned but not all are healthy or readable; 1 = an availability group or user database exists with no secondary capacity; 0 = no secondary capacity found

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Secondary replica capacity evidence could not be collected from this instance';
DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Groups INT = 0;
DECLARE @Secondaries INT = 0;
DECLARE @HealthySecondaries INT = 0;
DECLARE @Readable INT = 0;
DECLARE @AutoSeed INT = 0;
DECLARE @SecondaryNames NVARCHAR(400) = 'none';
DECLARE @GeoLinks INT = 0;
DECLARE @ZoneRedundant INT = 0;
DECLARE @Databases INT = 0;
DECLARE @Note NVARCHAR(300) = '';

IF @Edition = 5
BEGIN
    SELECT @Databases = COUNT(*) FROM sys.databases WHERE database_id > 4;

    BEGIN TRY
        IF OBJECT_ID('sys.geo_replication_links') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT @g = COUNT(*), @p = ISNULL(MAX(partner_server), ''none'')
FROM sys.geo_replication_links;';
            EXEC sp_executesql @Sql, N'@g INT OUTPUT, @p NVARCHAR(400) OUTPUT',
                 @g = @GeoLinks OUTPUT, @p = @SecondaryNames OUTPUT;
        END

        IF COL_LENGTH('sys.databases', 'is_zone_redundant') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT @z = COUNT(*) FROM sys.databases WHERE database_id > 4 AND is_zone_redundant = 1;';
            EXEC sp_executesql @Sql, N'@z INT OUTPUT', @z = @ZoneRedundant OUTPUT;
        END
    END TRY
    BEGIN CATCH
        SET @Note = ' Azure replica capacity metadata was not readable.';
    END CATCH

    SET @GeoLinks = ISNULL(@GeoLinks, 0);
    SET @ZoneRedundant = ISNULL(@ZoneRedundant, 0);
    SET @Databases = ISNULL(@Databases, 0);
    SET @SecondaryNames = ISNULL(@SecondaryNames, 'none');

    SET @Score = CASE
        WHEN @GeoLinks > 0 THEN 3
        WHEN @ZoneRedundant > 0 THEN 2
        WHEN @Databases > 0 THEN 1
        ELSE 0 END;

    SET @Finding = CONCAT('Azure SQL Database: user databases = ', @Databases,
        ', geo-secondary links = ', @GeoLinks, ' on partner server ', @SecondaryNames,
        ', zone-redundant databases = ', @ZoneRedundant, '.', @Note);
END
ELSE
BEGIN
    BEGIN TRY
        IF OBJECT_ID('sys.dm_hadr_availability_replica_states') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT @a = (SELECT COUNT(*) FROM sys.availability_groups),
       @s = (SELECT COUNT(*) FROM sys.dm_hadr_availability_replica_states WHERE role_desc = ''SECONDARY''),
       @h = (SELECT COUNT(*) FROM sys.dm_hadr_availability_replica_states
             WHERE role_desc = ''SECONDARY'' AND synchronization_health_desc = ''HEALTHY''),
       @r = (SELECT COUNT(*) FROM sys.availability_replicas
             WHERE secondary_role_allow_connections_desc <> ''NO''),
       @d = (SELECT COUNT(*) FROM sys.availability_replicas WHERE seeding_mode_desc = ''AUTOMATIC''),
       @m = ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(200), ar.replica_server_name), '', '')
                    FROM sys.availability_replicas AS ar
                    JOIN sys.dm_hadr_availability_replica_states AS rs ON rs.replica_id = ar.replica_id
                    WHERE rs.role_desc = ''SECONDARY''), ''none'');';
            EXEC sp_executesql @Sql,
                 N'@a INT OUTPUT, @s INT OUTPUT, @h INT OUTPUT, @r INT OUTPUT, @d INT OUTPUT, @m NVARCHAR(400) OUTPUT',
                 @a = @Groups OUTPUT, @s = @Secondaries OUTPUT, @h = @HealthySecondaries OUTPUT,
                 @r = @Readable OUTPUT, @d = @AutoSeed OUTPUT, @m = @SecondaryNames OUTPUT;
        END
    END TRY
    BEGIN CATCH
        SET @Note = ' Always On secondary replica metadata was not readable.';
    END CATCH

    SET @Groups = ISNULL(@Groups, 0);
    SET @Secondaries = ISNULL(@Secondaries, 0);
    SET @HealthySecondaries = ISNULL(@HealthySecondaries, 0);
    SET @Readable = ISNULL(@Readable, 0);
    SET @AutoSeed = ISNULL(@AutoSeed, 0);
    SET @SecondaryNames = ISNULL(@SecondaryNames, 'none');

    SET @Score = CASE
        WHEN @Secondaries >= 1 AND @HealthySecondaries = @Secondaries
             AND (@Readable > 0 OR @AutoSeed > 0) THEN 3
        WHEN @Secondaries >= 1 THEN 2
        WHEN @Groups > 0 THEN 1
        ELSE 0 END;

    SET @Finding = CONCAT('Availability groups = ', @Groups,
        ', secondary replicas = ', @Secondaries, ' (', @SecondaryNames,
        '), reporting HEALTHY = ', @HealthySecondaries,
        ', readable secondaries = ', @Readable,
        ', automatic-seeding replicas = ', @AutoSeed, '.',
        CASE WHEN @Secondaries = 0
             THEN ' No secondary replica capacity is provisioned on this instance.'
             ELSE '' END,
        @Note);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
