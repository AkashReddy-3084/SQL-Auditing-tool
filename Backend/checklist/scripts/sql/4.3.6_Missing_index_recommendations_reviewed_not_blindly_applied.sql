-- Checklist: Missing-index recommendations reviewed (not blindly applied)
-- Scope: DATABASE
-- Scoring: 0=Fail (high ratio of unused recommended indexes), 1=Partial Pass (some unused recommended indexes), 2=Mostly Pass (no recommendations or all created indexes show usage)
-- NOTE: This script provides automated evidence. Full compliance requires human review.
-- NOTE: sys.dm_db_index_usage_stats is cleared on server restart; results reflect post-restart activity.

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
DECLARE @RecCount INT = 0;
DECLARE @UnusedIdxCount INT = 0;

-- Count active missing index recommendations with actual workload impact
SELECT @RecCount = COUNT(*)
FROM sys.dm_db_missing_index_group_stats g
JOIN sys.dm_db_missing_index_groups gi ON g.group_handle = gi.index_group_handle
JOIN sys.dm_db_missing_index_details d ON gi.index_handle = d.index_handle
WHERE (g.user_seeks > 0 OR g.user_scans > 0)
  AND d.object_id IS NOT NULL;

-- Count indexes on recommended tables that have zero usage (indicates blind application)
SELECT @UnusedIdxCount = COUNT(*)
FROM sys.indexes i
JOIN sys.tables t ON i.object_id = t.object_id
LEFT JOIN sys.dm_db_index_usage_stats u ON i.object_id = u.object_id AND i.index_id = u.index_id AND u.database_id = DB_ID()
WHERE i.type_desc IN ('CLUSTERED', 'NONCLUSTERED')
  AND (u.user_seeks IS NULL OR u.user_seeks = 0)
  AND (u.user_scans IS NULL OR u.user_scans = 0)
  AND t.name IN (SELECT DISTINCT OBJECT_NAME(d.object_id) FROM sys.dm_db_missing_index_details d WHERE d.object_id IS NOT NULL);

DECLARE @DbScore INT = 0;
IF @RecCount = 0 OR @UnusedIdxCount = 0
    SET @DbScore = 2;
ELSE IF @UnusedIdxCount < @RecCount
    SET @DbScore = 1;
ELSE
    SET @DbScore = 0;

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