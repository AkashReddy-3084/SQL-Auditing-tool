-- Checklist: Geo-replication / failover group configured for DR where required
-- Scope: SERVER
-- Scoring: 3 = a geo-replication link in CATCH_UP state, a distributed availability group, or a connected asynchronous-commit secondary; 2 = a geo-replication link or asynchronous-commit secondary is defined but not yet caught up or connected, or log shipping is configured; 1 = an availability group exists with no cross-site partner; 0 = no cross-site replication configured

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Disaster recovery replication evidence could not be collected from this instance';
DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Links INT = 0, @CatchUp INT = 0, @Suspended INT = 0;
DECLARE @Groups INT = 0, @Distributed INT = 0;
DECLARE @AsyncSecondaries INT = 0, @AsyncConnected INT = 0, @LogShipping INT = 0;
DECLARE @Partner NVARCHAR(300) = 'none';
DECLARE @Note NVARCHAR(300) = '';

IF @Edition = 5
BEGIN
    BEGIN TRY
        IF OBJECT_ID('sys.geo_replication_links') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT @l = COUNT(*),
       @c = ISNULL(SUM(CASE WHEN replication_state_desc = ''CATCH_UP'' THEN 1 ELSE 0 END), 0),
       @s = ISNULL(SUM(CASE WHEN replication_state_desc = ''SUSPENDED'' THEN 1 ELSE 0 END), 0),
       @p = ISNULL(MAX(partner_server), ''none'')
FROM sys.geo_replication_links;';
            EXEC sp_executesql @Sql,
                 N'@l INT OUTPUT, @c INT OUTPUT, @s INT OUTPUT, @p NVARCHAR(300) OUTPUT',
                 @l = @Links OUTPUT, @c = @CatchUp OUTPUT, @s = @Suspended OUTPUT, @p = @Partner OUTPUT;
        END
    END TRY
    BEGIN CATCH
        SET @Note = ' Azure geo-replication metadata was not readable.';
    END CATCH

    SET @Links = ISNULL(@Links, 0);
    SET @CatchUp = ISNULL(@CatchUp, 0);
    SET @Suspended = ISNULL(@Suspended, 0);
    SET @Partner = ISNULL(@Partner, 'none');

    SET @Score = CASE
        WHEN @CatchUp > 0 THEN 3
        WHEN @Links > 0 AND @Suspended < @Links THEN 2
        WHEN @Links > 0 THEN 1
        ELSE 0 END;

    SET @Finding = CONCAT('Azure SQL Database: geo-replication links = ', @Links,
        ', in CATCH_UP state = ', @CatchUp, ', suspended = ', @Suspended,
        ', partner server = ', @Partner, '.',
        CASE WHEN @Links = 0
             THEN ' No geo-replication link or failover group partner is registered for this logical server.'
             ELSE '' END,
        @Note);
END
ELSE
BEGIN
    BEGIN TRY
        IF OBJECT_ID('sys.availability_replicas') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT @a = (SELECT COUNT(*) FROM sys.availability_groups),
       @d = (SELECT COUNT(*) FROM sys.availability_groups WHERE is_distributed = 1),
       @s = (SELECT COUNT(*) FROM sys.availability_replicas WHERE availability_mode_desc = ''ASYNCHRONOUS_COMMIT''),
       @k = (SELECT COUNT(*) FROM sys.availability_replicas AS ar
             JOIN sys.dm_hadr_availability_replica_states AS rs ON rs.replica_id = ar.replica_id
             WHERE ar.availability_mode_desc = ''ASYNCHRONOUS_COMMIT'' AND rs.connected_state = 1),
       @p = ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(200), ar.replica_server_name), '', '')
                    FROM sys.availability_replicas AS ar
                    WHERE ar.availability_mode_desc = ''ASYNCHRONOUS_COMMIT''), ''none'');';
            EXEC sp_executesql @Sql,
                 N'@a INT OUTPUT, @d INT OUTPUT, @s INT OUTPUT, @k INT OUTPUT, @p NVARCHAR(300) OUTPUT',
                 @a = @Groups OUTPUT, @d = @Distributed OUTPUT, @s = @AsyncSecondaries OUTPUT,
                 @k = @AsyncConnected OUTPUT, @p = @Partner OUTPUT;
        END
    END TRY
    BEGIN CATCH
        SET @Note = ' Always On replica metadata was not readable.';
    END CATCH

    BEGIN TRY
        IF OBJECT_ID('msdb.dbo.log_shipping_primary_databases') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT @g = COUNT(*) FROM msdb.dbo.log_shipping_primary_databases;';
            EXEC sp_executesql @Sql, N'@g INT OUTPUT', @g = @LogShipping OUTPUT;
        END
    END TRY
    BEGIN CATCH
        SET @Note = @Note + ' Log shipping metadata was not readable.';
    END CATCH

    SET @Groups = ISNULL(@Groups, 0);
    SET @Distributed = ISNULL(@Distributed, 0);
    SET @AsyncSecondaries = ISNULL(@AsyncSecondaries, 0);
    SET @AsyncConnected = ISNULL(@AsyncConnected, 0);
    SET @LogShipping = ISNULL(@LogShipping, 0);
    SET @Partner = ISNULL(@Partner, 'none');

    SET @Score = CASE
        WHEN @Distributed > 0 OR @AsyncConnected > 0 THEN 3
        WHEN @AsyncSecondaries > 0 OR @LogShipping > 0 THEN 2
        WHEN @Groups > 0 THEN 1
        ELSE 0 END;

    SET @Finding = CONCAT('Availability groups = ', @Groups,
        ', distributed availability groups = ', @Distributed,
        ', asynchronous-commit replicas = ', @AsyncSecondaries,
        ' (connected = ', @AsyncConnected, '): ', @Partner,
        '; log shipping primary databases = ', @LogShipping, '.',
        CASE WHEN @Distributed = 0 AND @AsyncSecondaries = 0 AND @LogShipping = 0
             THEN ' No asynchronous DR replica, distributed availability group or log shipping partner is configured.'
             ELSE '' END,
        @Note);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
