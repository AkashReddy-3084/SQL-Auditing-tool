-- Checklist: Redundancy configured for the production database (replicas / zone redundancy)
-- Scope: DATABASE
-- Scoring: 0 = No redundancy configured; 1 = 1 replica configured; 2 = 2 replicas or zone redundancy ON; 3 = 3+ replicas and zone redundancy ON
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
        DECLARE @ReplicaCount INT = 0;
        DECLARE @ZoneRedundant BIT = 0;

        IF OBJECT_ID('sys.dm_hadr_database_replica_states') IS NOT NULL
        BEGIN
            SELECT @ReplicaCount = COUNT(*)
            FROM sys.dm_hadr_database_replica_states drs
            JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
            WHERE drs.database_id = DB_ID();
        END

        IF OBJECT_ID('sys.database_service_objectives') IS NOT NULL
        BEGIN
            SELECT @ZoneRedundant = MAX(CASE WHEN zone_redundant = 1 THEN 1 ELSE 0 END)
            FROM sys.database_service_objectives;
        END

        IF @ReplicaCount >= 3 AND @ZoneRedundant = 1 SET @DbScore = 3;
        ELSE IF @ReplicaCount >= 2 OR @ZoneRedundant = 1 SET @DbScore = 2;
        ELSE IF @ReplicaCount = 1 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

        INSERT INTO #DbResults VALUES (@pDbName, @DbScore);';
        EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(256)', @pDbName = @DbName;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;