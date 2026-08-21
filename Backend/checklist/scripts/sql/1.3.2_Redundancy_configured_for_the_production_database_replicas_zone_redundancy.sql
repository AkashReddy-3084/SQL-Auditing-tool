-- Checklist: Redundancy configured for the production database (replicas / zone redundancy)
-- Scope: DATABASE
-- Scoring: 0: No redundancy configured. 1: Asynchronous replica or partial redundancy. 2: Synchronous replica or standard built-in redundancy. 3: Synchronous replica with zone redundancy or fully compliant high availability.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: Evaluate only current database
    SET @DbName = DB_NAME();
    
    DECLARE @ZoneRedundant BIT = 0;
    SELECT @ZoneRedundant = MAX(is_zone_redundant) 
    FROM sys.database_service_objectives;
    
    DECLARE @DbScore INT = 0;
    DECLARE @DbFinding NVARCHAR(MAX) = '';
    
    IF @ZoneRedundant = 1
    BEGIN
        SET @DbScore = 3;
        SET @DbFinding = 'Zone redundancy enabled';
    END
    ELSE
    BEGIN
        -- Azure SQL DB has built-in redundancy (automatic backups, transparent failover for P/GP tiers)
        DECLARE @ServiceTier NVARCHAR(128);
        SELECT @ServiceTier = service_objective FROM sys.database_service_objectives;
        
        IF @ServiceTier LIKE 'P%' OR @ServiceTier LIKE 'GP%' OR @ServiceTier LIKE 'BC%' OR @ServiceTier LIKE 'HS%'
        BEGIN
            SET @DbScore = 2;
            SET @DbFinding = 'Standard built-in redundancy (no zone redundancy)';
        END
        ELSE
        BEGIN
            SET @DbScore = 0;
            SET @DbFinding = 'No explicit redundancy configured (low-tier service objective)';
        END
    END
    
    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @DbScore, @DbFinding);
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: Iterate user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4
      AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @IsHadrEnabled BIT = 0;
            SELECT @IsHadrEnabled = is_hadr_enabled FROM sys.databases WHERE name = DB_NAME();
            
            DECLARE @DbScore INT = 0;
            DECLARE @DbFinding NVARCHAR(MAX) = N'';
            
            IF @IsHadrEnabled = 1
            BEGIN
                DECLARE @SyncState NVARCHAR(60);
                SELECT @SyncState = synchronization_state_desc 
                FROM sys.dm_hadr_database_replica_states 
                WHERE database_id = DB_ID() AND is_local = 1;
                
                IF @SyncState = N''SYNCHRONIZED''
                BEGIN
                    SET @DbScore = 3;
                    SET @DbFinding = N''Synchronous AG replica configured'';
                END
                ELSE IF @SyncState = N''SYNCHRONIZING''
                BEGIN
                    SET @DbScore = 2;
                    SET @DbFinding = N''AG replica synchronizing'';
                END
                ELSE
                BEGIN
                    SET @DbScore = 1;
                    SET @DbFinding = N''Asynchronous AG replica configured'';
                END
            END
            ELSE
            BEGIN
                SET @DbScore = 0;
                SET @DbFinding = N''No HA redundancy configured'';
            END
            
            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@pDbName, @DbScore, @DbFinding);
            ';
            EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(128)', @pDbName = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Database evaluation failed');
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = (
    SELECT STRING_AGG(DbName, ', ')
    FROM #DbResults
);

SET @Score = ISNULL(
    (SELECT MIN(DbScore) FROM #DbResults),
    0
);

SET @Finding = ISNULL(
    (
        SELECT STRING_AGG(DbName + ': ' + Finding, '; ')
        FROM #DbResults
        WHERE Finding IS NOT NULL
          AND Finding <> ''
    ),
    'No non-compliant findings found'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;