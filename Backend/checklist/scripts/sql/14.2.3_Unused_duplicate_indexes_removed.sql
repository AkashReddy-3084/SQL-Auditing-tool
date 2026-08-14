-- Checklist: Unused/duplicate indexes removed
-- Scope: DATABASE
-- Scoring: 0 = >20% unused indexes; 1 = 10-20%; 2 = 5-10%; 3 = <5% unused indexes. NOTE: Usage stats reset on server restart; full compliance requires human review.
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
        
        SELECT @TotalIdx = COUNT(*) FROM sys.indexes WHERE type > 0;
        
        SELECT @UnusedIdx = COUNT(*) FROM sys.indexes i
        LEFT JOIN sys.dm_db_index_usage_stats u 
            ON i.object_id = u.object_id 
            AND i.index_id = u.index_id 
            AND u.database_id = DB_ID()
        WHERE i.type > 0 
          AND (u.user_updates IS NULL OR u.user_updates = 0);

        DECLARE @Pct FLOAT = CASE WHEN @TotalIdx = 0 THEN 0 ELSE CAST(@UnusedIdx AS FLOAT) / @TotalIdx * 100.0 END;
        
        DECLARE @DbScore INT = CASE
            WHEN @Pct < 5 THEN 3
            WHEN @Pct < 10 THEN 2
            WHEN @Pct < 20 THEN 1
            ELSE 0
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

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 3);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;