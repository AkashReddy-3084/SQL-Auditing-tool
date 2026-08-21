/* Checklist 1.3.2 - Redundancy configured for the production database (replicas / zone redundancy)
   Read-only. Engine-specific catalog views are reached through dynamic SQL so the batch compiles
   on SQL Server, Azure SQL Managed Instance and Azure SQL Database alike. */
SET NOCOUNT ON;

DECLARE @EngineEdition   INT           = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @IsAzureSqlDb    BIT           = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 5 THEN 1 ELSE 0 END;
DECLARE @IsClustered     INT           = ISNULL(CAST(SERVERPROPERTY('IsClustered') AS INT), 0);
DECLARE @IsHadrEnabled   INT           = ISNULL(CAST(SERVERPROPERTY('IsHadrEnabled') AS INT), 0);
DECLARE @DatabaseQueried NVARCHAR(256) = ISNULL(CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(256)), @@SERVERNAME);

DECLARE @sql                   NVARCHAR(MAX);
DECLARE @AgCount               INT = 0;
DECLARE @MaxReplicasPerAg      INT = 0;
DECLARE @UserDbCount           INT = 0;
DECLARE @ProtectedDbCount      INT = 0;
DECLARE @ZoneRedundantCount    INT = 0;
DECLARE @GeoLinkCount          INT = 0;
DECLARE @SecondaryReplicaCount INT = 0;
DECLARE @ServiceObjective      NVARCHAR(128) = NULL;
DECLARE @MethodList            NVARCHAR(MAX) = NULL;
DECLARE @UnprotectedList       NVARCHAR(MAX) = NULL;
DECLARE @Result                NVARCHAR(20);
DECLARE @Score                 INT;
DECLARE @Finding               NVARCHAR(MAX);

IF OBJECT_ID('tempdb..#Protected') IS NOT NULL DROP TABLE #Protected;
CREATE TABLE #Protected
(
    database_id   INT           NOT NULL,
    database_name SYSNAME       NOT NULL,
    method        NVARCHAR(40)  NOT NULL
);

IF @IsAzureSqlDb = 1
BEGIN
    SET @DatabaseQueried = DB_NAME();
    SET @UserDbCount = 1;

    BEGIN TRY
        SET @sql = N'SELECT @c = COUNT(*) FROM sys.database_service_objectives WHERE database_id = DB_ID() AND zone_redundant = 1;';
        EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @ZoneRedundantCount OUTPUT;
    END TRY
    BEGIN CATCH
        SET @ZoneRedundantCount = 0;
    END CATCH

    BEGIN TRY
        SET @sql = N'SELECT @c = COUNT(*) FROM sys.geo_replication_links WHERE database_id = DB_ID();';
        EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @GeoLinkCount OUTPUT;
    END TRY
    BEGIN CATCH
        SET @GeoLinkCount = 0;
    END CATCH

    BEGIN TRY
        SET @sql = N'SELECT @c = COUNT(*) FROM sys.dm_database_replica_states WHERE is_local = 0;';
        EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @SecondaryReplicaCount OUTPUT;
    END TRY
    BEGIN CATCH
        SET @SecondaryReplicaCount = 0;
    END CATCH

    BEGIN TRY
        SET @ServiceObjective = CAST(DATABASEPROPERTYEX(DB_NAME(), 'ServiceObjective') AS NVARCHAR(128));
    END TRY
    BEGIN CATCH
        SET @ServiceObjective = NULL;
    END CATCH

    IF @ZoneRedundantCount > 0 OR @GeoLinkCount > 0
        SET @Score = 3;
    ELSE IF @SecondaryReplicaCount > 0
        SET @Score = 2;
    ELSE
        SET @Score = 1;

    SET @Finding =
        N'Azure SQL Database ''' + ISNULL(DB_NAME(), N'(unknown)') + N''''
        + N' (service objective: ' + ISNULL(@ServiceObjective, N'unknown') + N'). '
        + N'Zone redundant: ' + CASE WHEN @ZoneRedundantCount > 0 THEN N'YES' ELSE N'NO' END + N'. '
        + N'Active geo-replication links: ' + CAST(@GeoLinkCount AS NVARCHAR(20)) + N'. '
        + N'Non-local HA secondary replicas visible: ' + CAST(@SecondaryReplicaCount AS NVARCHAR(20)) + N'. '
        + CASE
              WHEN @Score = 3 THEN N'Redundancy is configured beyond the local HA quorum.'
              WHEN @Score = 2 THEN N'Only local high-availability replicas are present - the database is not zone redundant and has no geo-replication secondary.'
              ELSE N'No zone redundancy, geo-replication secondary or additional replica was detected for this database.'
          END;
END
ELSE
BEGIN
    SELECT @UserDbCount = COUNT(*)
    FROM sys.databases
    WHERE database_id > 4
      AND state = 0
      AND source_database_id IS NULL;

    IF @IsHadrEnabled = 1 AND OBJECT_ID('sys.availability_groups') IS NOT NULL
    BEGIN
        BEGIN TRY
            SET @sql = N'SELECT @c = COUNT(*) FROM sys.availability_groups;';
            EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @AgCount OUTPUT;

            SET @sql = N'SELECT @c = ISNULL(MAX(x.rc), 0) FROM (SELECT COUNT(*) AS rc FROM sys.availability_replicas GROUP BY group_id) AS x;';
            EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @MaxReplicasPerAg OUTPUT;

            SET @sql = N'INSERT INTO #Protected (database_id, database_name, method)
                         SELECT DISTINCT d.database_id, d.name, N''Always On availability group''
                         FROM sys.dm_hadr_database_replica_states AS drs
                         INNER JOIN sys.databases AS d ON d.database_id = drs.database_id
                         WHERE drs.is_local = 1 AND d.database_id > 4;';
            EXEC sp_executesql @sql;
        END TRY
        BEGIN CATCH
            SET @AgCount = ISNULL(@AgCount, 0);
        END CATCH
    END

    BEGIN TRY
        SET @sql = N'INSERT INTO #Protected (database_id, database_name, method)
                     SELECT d.database_id, d.name, N''Database mirroring''
                     FROM sys.database_mirroring AS dm
                     INNER JOIN sys.databases AS d ON d.database_id = dm.database_id
                     WHERE dm.mirroring_guid IS NOT NULL AND d.database_id > 4;';
        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
        /* sys.database_mirroring unavailable on this edition - ignore */
        SET @sql = NULL;
    END CATCH

    IF OBJECT_ID('msdb.dbo.log_shipping_primary_databases') IS NOT NULL
    BEGIN
        BEGIN TRY
            SET @sql = N'INSERT INTO #Protected (database_id, database_name, method)
                         SELECT DISTINCT d.database_id, d.name, N''Log shipping''
                         FROM msdb.dbo.log_shipping_primary_databases AS lsp
                         INNER JOIN sys.databases AS d ON d.name = lsp.primary_database
                         WHERE d.database_id > 4;';
            EXEC sp_executesql @sql;
        END TRY
        BEGIN CATCH
            SET @sql = NULL;
        END CATCH
    END

    SELECT @ProtectedDbCount = COUNT(DISTINCT p.database_id) FROM #Protected AS p;

    SELECT @MethodList = STUFF((
        SELECT DISTINCT N', ' + p.method
        FROM #Protected AS p
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

    SELECT @UnprotectedList = STUFF((
        SELECT TOP (10) N', ' + d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.source_database_id IS NULL
          AND NOT EXISTS (SELECT 1 FROM #Protected AS p WHERE p.database_id = d.database_id)
        ORDER BY d.name
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

    IF @UserDbCount > 0 AND @ProtectedDbCount >= @UserDbCount
        SET @Score = 3;
    ELSE IF @ProtectedDbCount > 0 OR @IsClustered = 1
        SET @Score = 2;
    ELSE
        SET @Score = 1;

    SET @Finding =
        N'SQL Server instance ''' + @DatabaseQueried + N''' (EngineEdition ' + CAST(@EngineEdition AS NVARCHAR(10)) + N'). '
        + N'Always On enabled: ' + CASE WHEN @IsHadrEnabled = 1 THEN N'YES' ELSE N'NO' END
        + N'; availability groups: ' + CAST(@AgCount AS NVARCHAR(20))
        + N'; max replicas per group: ' + CAST(@MaxReplicasPerAg AS NVARCHAR(20))
        + N'; failover cluster instance: ' + CASE WHEN @IsClustered = 1 THEN N'YES' ELSE N'NO' END + N'. '
        + CAST(@ProtectedDbCount AS NVARCHAR(20)) + N' of ' + CAST(@UserDbCount AS NVARCHAR(20))
        + N' online user database(s) are covered by a database-level redundancy method'
        + CASE WHEN @MethodList IS NULL THEN N'' ELSE N' (' + @MethodList + N')' END + N'. '
        + CASE
              WHEN @Score = 3 THEN N'All user databases have a redundant copy.'
              WHEN @UnprotectedList IS NOT NULL THEN N'Databases without a redundant copy (first 10): ' + @UnprotectedList + N'.'
              ELSE N'No user database has a redundant copy.'
          END;
END

SET @Result = CASE WHEN @Score = 3 THEN N'PASS' ELSE N'FAIL' END;

IF OBJECT_ID('tempdb..#Protected') IS NOT NULL DROP TABLE #Protected;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;