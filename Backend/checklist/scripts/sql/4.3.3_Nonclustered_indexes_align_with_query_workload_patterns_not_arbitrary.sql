-- Checklist: Nonclustered indexes align with query/workload patterns (not arbitrary)
-- Scope: DATABASE
-- Scoring: 0 = >30% unused, 1 = 15-30% unused, 2 = 5-15% unused, 3 = <5% unused
-- NOTE: sys.dm_db_index_usage_stats resets on server restart. Scores reflect usage since last restart.
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
        DECLARE @TotalIdx INT, @UnusedIdx INT;
        SELECT @TotalIdx = COUNT(*) FROM sys.indexes i JOIN sys.tables t ON i.object_id = t.object_id WHERE i.type = 2 AND i.is_hypothetical = 0;
        SELECT @UnusedIdx = COUNT(*) FROM sys.indexes i JOIN sys.tables t ON i.object_id = t.object_id WHERE i.type = 2 AND i.is_hypothetical = 0 AND NOT EXISTS (SELECT 1 FROM sys.dm_db_index_usage_stats us WHERE us.object_id = i.object_id AND us.index_id = i.index_id AND us.database_id = DB_ID() AND (us.user_seeks + us.user_scans + us.user_lookups) > 0);
        SELECT CASE 
            WHEN @TotalIdx = 0 THEN 3
            ELSE CASE 
                WHEN CAST(@UnusedIdx AS FLOAT) / @TotalIdx <= 0.05 THEN 3
                WHEN CAST(@UnusedIdx AS FLOAT) / @TotalIdx <= 0.15 THEN 2
                WHEN CAST(@UnusedIdx AS FLOAT) / @TotalIdx <= 0.30 THEN 1
                ELSE 0
            END
        END;';
        INSERT INTO #DbResults (DbName, DbScore)
        EXEC sp_executesql @Sql;
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