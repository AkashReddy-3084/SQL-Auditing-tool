-- Checklist: Unused/duplicate indexes removed
-- Scope: DATABASE
-- Scoring: 3 = no unused and no overlapping indexes; 2 = one category has findings; 1 = both categories have findings; 0 = index evidence could not be read
-- NOTE: Automated evidence identifies cleanup candidates; workload history and intentional retention require human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Index evidence unavailable';
DECLARE @UnusedIndexCount INT = 0;
DECLARE @OverlappingIndexCount INT = 0;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT @UnusedIndexCount = COUNT(*)
    FROM sys.indexes AS i
    INNER JOIN sys.objects AS o ON o.object_id = i.object_id
    LEFT JOIN sys.dm_db_index_usage_stats AS u
        ON u.object_id = i.object_id
       AND u.index_id = i.index_id
       AND u.database_id = DB_ID()
    WHERE o.is_ms_shipped = 0
      AND i.index_id > 1
      AND i.is_primary_key = 0
      AND i.is_unique_constraint = 0
      AND ISNULL(u.user_seeks, 0) + ISNULL(u.user_scans, 0) + ISNULL(u.user_lookups, 0) = 0;

    SELECT @OverlappingIndexCount = COUNT(*)
    FROM
    (
        SELECT i.object_id, ic.column_id
        FROM sys.indexes AS i
        INNER JOIN sys.index_columns AS ic
            ON ic.object_id = i.object_id
           AND ic.index_id = i.index_id
           AND ic.key_ordinal = 1
        INNER JOIN sys.objects AS o ON o.object_id = i.object_id
        WHERE o.is_ms_shipped = 0
          AND i.index_id > 1
        GROUP BY i.object_id, ic.column_id
        HAVING COUNT(*) > 1
    ) AS overlapping;
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

SET @Score = CASE
    WHEN @ReadError = 1 THEN 0
    WHEN @UnusedIndexCount = 0 AND @OverlappingIndexCount = 0 THEN 3
    WHEN (@UnusedIndexCount > 0 AND @OverlappingIndexCount = 0)
      OR (@UnusedIndexCount = 0 AND @OverlappingIndexCount > 0) THEN 2
    WHEN @UnusedIndexCount > 0 AND @OverlappingIndexCount > 0 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'unused indexes = ', @UnusedIndexCount,
    N'; overlapping leading-column groups = ', @OverlappingIndexCount,
    CASE WHEN @ReadError = 1 THEN N'; one or more index sources could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
