-- Checklist: Partitioning strategy defined for large tables (by date/range) where beneficial
-- Scope: DATABASE
-- Scoring: 0=No partitioned tables, 1=Partitioned tables exist but none of the top 5 largest are partitioned, 2=Some of the top 5 largest tables are partitioned, 3=All of the top 5 largest tables are partitioned
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
        DECLARE @LargeTables INT = 0;
        DECLARE @LargePartitionedTables INT = 0;
        DECLARE @PartitionedTables INT = 0;
        DECLARE @DbScore INT = 0;

        SELECT @LargeTables = COUNT(*)
        FROM (
            SELECT TOP 5 t.object_id
            FROM sys.tables t
            JOIN sys.dm_db_partition_stats p ON t.object_id = p.object_id
            WHERE t.type = ''U''
            GROUP BY t.object_id
            ORDER BY SUM(p.used_page_count) DESC
        ) AS TopTables;

        SELECT @LargePartitionedTables = COUNT(*)
        FROM (
            SELECT TOP 5 t.object_id
            FROM sys.tables t
            JOIN sys.dm_db_partition_stats p ON t.object_id = p.object_id
            WHERE t.type = ''U''
            GROUP BY t.object_id
            ORDER BY SUM(p.used_page_count) DESC
        ) AS TopTables
        JOIN sys.indexes i ON TopTables.object_id = i.object_id
        WHERE i.type <= 1 AND i.data_space_id > 100;

        SELECT @PartitionedTables = COUNT(DISTINCT object_id)
        FROM sys.indexes
        WHERE type <= 1 AND data_space_id > 100;

        IF @LargeTables = 0 SET @DbScore = 3;
        ELSE IF @PartitionedTables = 0 SET @DbScore = 0;
        ELSE IF @LargePartitionedTables = 0 SET @DbScore = 1;
        ELSE IF @LargePartitionedTables < @LargeTables SET @DbScore = 2;
        ELSE SET @DbScore = 3;

        INSERT INTO #DbResults VALUES (@DB, @DbScore);';
        EXEC sp_executesql @Sql, N'@DB NVARCHAR(256)', @DB = @DbName;
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