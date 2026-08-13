-- Checklist: Full load reserved for small reference/dimension tables or initial loads
-- Scope: DATABASE
-- Scoring: 0=Large tables (>100k rows) lack incremental config (CDC/CT), implying full loads; 1=No clear incremental strategy or mixed evidence; 2=Full load procs only on small tables, incremental config exists for larger tables; 3=Fully incremental strategy with full load strictly reserved for initial/small tables
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
        DECLARE @LargeNoIncremental INT = 0;
        DECLARE @SmallNoIncremental INT = 0;
        DECLARE @IncrementalCount INT = 0;

        -- Count large tables without incremental tracking (likely full-loaded)
        SELECT @LargeNoIncremental = COUNT(*) FROM (
            SELECT t.object_id
            FROM sys.tables t
            JOIN sys.dm_db_partition_stats p ON t.object_id = p.object_id AND p.index_id IN (0,1)
            WHERE t.is_tracked_by_cdc = 0
              AND NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables ctt WHERE ctt.object_id = t.object_id)
            GROUP BY t.object_id
            HAVING SUM(p.rows) > 100000
        ) AS Large;

        -- Count small tables without incremental tracking (candidates for full load)
        SELECT @SmallNoIncremental = COUNT(*) FROM (
            SELECT t.object_id
            FROM sys.tables t
            JOIN sys.dm_db_partition_stats p ON t.object_id = p.object_id AND p.index_id IN (0,1)
            WHERE t.is_tracked_by_cdc = 0
              AND NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables ctt WHERE ctt.object_id = t.object_id)
            GROUP BY t.object_id
            HAVING SUM(p.rows) <= 100000
        ) AS Small;

        -- Count tables with incremental tracking enabled
        SELECT @IncrementalCount = COUNT(*) FROM sys.tables t
        WHERE t.is_tracked_by_cdc = 1
           OR EXISTS (SELECT 1 FROM sys.change_tracking_tables ctt WHERE ctt.object_id = t.object_id);

        DECLARE @DbScore INT;
        IF @LargeNoIncremental > 0 SET @DbScore = 0;
        ELSE IF @IncrementalCount = 0 SET @DbScore = 1;
        ELSE IF @LargeNoIncremental = 0 AND @SmallNoIncremental > 0 SET @DbScore = 2;
        ELSE IF @LargeNoIncremental = 0 AND @SmallNoIncremental = 0 SET @DbScore = 3;
        ELSE SET @DbScore = 1;

        INSERT INTO #DbResults VALUES (' + QUOTENAME(@DbName, '''') + N', @DbScore);';
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
SET @Result = CASE WHEN @Score >= 2 THEN ''Pass'' ELSE ''Fail'' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;