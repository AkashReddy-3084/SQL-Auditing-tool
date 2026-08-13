-- Checklist: Geo-replication / failover group configured for DR where required
-- Scope: DATABASE
-- Scoring: 3=Explicit failover group/AG configured, 2=Proxy DR evidence (read-only routing/secondary replica), 1=No DR config found, 0=Database offline/unreachable
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @DbScore INT = 0;
        
        -- Check Azure Failover Group / Read-Only Routing (Azure SQL DB/MI)
        IF OBJECT_ID('sys.database_service_objectives') IS NOT NULL
        BEGIN
            IF EXISTS (SELECT 1 FROM sys.database_service_objectives WHERE failover_group_name IS NOT NULL)
                SET @DbScore = 3;
            ELSE IF EXISTS (SELECT 1 FROM sys.database_service_objectives WHERE read_only_routing_url IS NOT NULL)
                SET @DbScore = 2;
        END
        
        -- Check On-Prem Always On / Proxy Evidence
        IF @DbScore = 0 AND SERVERPROPERTY('IsHadrEnabled') = 1
        BEGIN
            -- Check if CURRENT database is part of an AG (DB-level scope)
            IF EXISTS (SELECT 1 FROM sys.dm_hadr_database_replica_states WHERE database_id = DB_ID())
                SET @DbScore = 3;
            ELSE IF EXISTS (SELECT 1 FROM sys.dm_hadr_availability_replica_states WHERE role = 2)
                SET @DbScore = 2;
        END
        
        IF @DbScore = 0 SET @DbScore = 1;
        INSERT INTO #DbResults VALUES (@DbName, @DbScore);
        ';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Aggregate: worst-case score across all databases
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;