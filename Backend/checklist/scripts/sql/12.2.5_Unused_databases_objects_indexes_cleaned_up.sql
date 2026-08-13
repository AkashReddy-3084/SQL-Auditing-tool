-- Checklist: Unused databases/objects/indexes cleaned up
-- Scope: DATABASE
-- Scoring: 0 = >50% unused, 1 = 20-50%, 2 = 5-20%, 3 = <5% unused indexes/procedures
-- NOTE: DMV stats reset on server restart. This script provides automated evidence. Full compliance requires human review.
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
        DECLARE @TotalIndexes INT, @UnusedIndexes INT;
        DECLARE @TotalProcs INT, @UnusedProcs INT;
        DECLARE @UnusedPct DECIMAL(5,2);
        DECLARE @DbScore INT;

        -- Aggregate index usage per index to avoid partition overcounting
        SELECT @TotalIndexes = COUNT(*),
               @UnusedIndexes = SUM(CASE WHEN ius.total_usage IS NULL OR ius.total_usage = 0 THEN 1 ELSE 0 END)
        FROM sys.indexes i
        LEFT JOIN (
            SELECT object_id, index_id, SUM(user_seeks + user_scans + user_lookups + user_updates) AS total_usage
            FROM sys.dm_db_index_usage_stats
            WHERE database_id = DB_ID()
            GROUP BY object_id, index_id
        ) ius ON i.object_id = ius.object_id AND i.index_id = ius.index_id
        WHERE i.type > 0;

        -- Check unused procedures with explicit database_id filter to prevent cross-DB false matches
        SELECT @TotalProcs = COUNT(*),
               @UnusedProcs = SUM(CASE WHEN pstats.object_id IS NULL THEN 1 ELSE 0 END)
        FROM sys.procedures p
        LEFT JOIN sys.dm_exec_procedure_stats pstats
            ON p.object_id = pstats.object_id AND pstats.database_id = DB_ID();

        SET @UnusedPct = CASE WHEN (@TotalIndexes + @TotalProcs) = 0 THEN 0
                              ELSE CAST((@UnusedIndexes + @UnusedProcs) AS DECIMAL) / (@TotalIndexes + @TotalProcs) * 100 END;

        IF @UnusedPct < 5 SET @DbScore = 3;
        ELSE IF @UnusedPct < 20 SET @DbScore = 2;
        ELSE IF @UnusedPct < 50 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

        INSERT INTO #DbResults VALUES (@DbNameParam, @DbScore);';
        
        EXEC sp_executesql @Sql, N'@DbNameParam NVARCHAR(256)', @DbNameParam = @DbName;
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