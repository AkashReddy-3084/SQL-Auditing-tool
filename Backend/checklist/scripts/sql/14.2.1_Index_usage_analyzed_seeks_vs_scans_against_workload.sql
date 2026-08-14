-- Checklist: Index usage analyzed (seeks vs scans) against workload
-- Scope: DATABASE
-- Scoring: 0 = No stats available or >50% unused indexes; 1 = 20-50% unused; 2 = 5-20% unused; 3 = <5% unused
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
        SET @Sql = N'DECLARE @TotalIndexes INT, @UnusedIndexes INT, @DbScore INT;
        SELECT @TotalIndexes = COUNT(*), @UnusedIndexes = ISNULL(SUM(CASE WHEN ISNULL(s.user_seeks,0) + ISNULL(s.user_scans,0) + ISNULL(s.user_lookups,0) = 0 THEN 1 ELSE 0 END), 0)
        FROM sys.indexes i
        JOIN sys.tables t ON i.object_id = t.object_id
        LEFT JOIN sys.dm_db_index_usage_stats s ON i.object_id = s.object_id AND i.index_id = s.index_id AND s.database_id = DB_ID()
        WHERE i.type_desc IN (''CLUSTERED'', ''NONCLUSTERED'');

        IF @TotalIndexes = 0 SET @DbScore = 0;
        ELSE BEGIN
            DECLARE @UnusedPct FLOAT = CAST(@UnusedIndexes AS FLOAT) / @TotalIndexes;
            SET @DbScore = CASE 
                WHEN @UnusedPct < 0.05 THEN 3
                WHEN @UnusedPct < 0.20 THEN 2
                WHEN @UnusedPct < 0.50 THEN 1
                ELSE 0
            END;
        END;
        INSERT INTO #DbResults VALUES (@DbName, @DbScore);';
        EXEC sp_executesql @Sql, N'@DbName NVARCHAR(256)', @DbName = @DbName;
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
-- NOTE: This script provides automated evidence. Full compliance requires human review.