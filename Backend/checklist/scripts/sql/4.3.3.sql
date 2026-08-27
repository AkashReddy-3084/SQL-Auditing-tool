-- Checklist: Nonclustered indexes align with query/workload patterns (not arbitrary)
-- Scope: DATABASE
-- Scoring: 2 = most nonclustered indexes have seek activity and none are unused; 1 = nonclustered indexes exist but usage evidence is weak; 0 = no nonclustered indexes. Alignment with workload patterns requires human review.
-- NOTE: Automated evidence only; whether an index is appropriate requires workload review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Index usage metadata could not be evaluated';
DECLARE @NonclusteredIndexes INT = 0;
DECLARE @SeekIndexes INT = 0;
DECLARE @UnusedIndexes INT = 0;

BEGIN TRY
    SELECT @NonclusteredIndexes = COUNT(*)
    FROM sys.indexes AS i JOIN sys.tables AS t ON t.object_id = i.object_id
    WHERE t.is_ms_shipped = 0 AND i.index_id > 1;

    SELECT @SeekIndexes = COUNT(*)
    FROM sys.indexes AS i JOIN sys.tables AS t ON t.object_id = i.object_id
    JOIN sys.dm_db_index_usage_stats AS u ON u.object_id = i.object_id AND u.index_id = i.index_id AND u.database_id = DB_ID()
    WHERE t.is_ms_shipped = 0 AND i.index_id > 1 AND u.user_seeks > u.user_scans;

    SELECT @UnusedIndexes = COUNT(*)
    FROM sys.indexes AS i JOIN sys.tables AS t ON t.object_id = i.object_id
    LEFT JOIN sys.dm_db_index_usage_stats AS u ON u.object_id = i.object_id AND u.index_id = i.index_id AND u.database_id = DB_ID()
    WHERE t.is_ms_shipped = 0 AND i.index_id > 1 AND ISNULL(u.user_seeks, 0) + ISNULL(u.user_scans, 0) + ISNULL(u.user_lookups, 0) = 0;

    SET @Score = CASE WHEN @NonclusteredIndexes = 0 THEN 0 WHEN @UnusedIndexes = 0 AND @SeekIndexes >= @NonclusteredIndexes * 0.75 THEN 2 ELSE 1 END;
    SET @Finding = N'nc_indexes=' + CONVERT(NVARCHAR(20), @NonclusteredIndexes) + N', seek_indexes=' + CONVERT(NVARCHAR(20), @SeekIndexes) + N', unused_indexes=' + CONVERT(NVARCHAR(20), @UnusedIndexes);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read index usage metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;