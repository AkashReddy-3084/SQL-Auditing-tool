-- Checklist: Unused databases/objects/indexes cleaned up
-- Scope: DATABASE
-- Scoring: 3 = no empty tables and no unused nonclustered indexes; 2 = one category has findings; 1 = both categories have findings; 0 = evidence could not be read
-- NOTE: Automated evidence identifies cleanup candidates; whether an object is intentionally retained requires human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Cleanup evidence unavailable';
DECLARE @EmptyTableCount INT = 0;
DECLARE @UnusedIndexCount INT = 0;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT @EmptyTableCount = COUNT(*)
    FROM sys.tables AS t
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM sys.partitions AS p
        WHERE p.object_id = t.object_id
          AND p.index_id IN (0, 1)
          AND p.rows > 0
    );

    SELECT @UnusedIndexCount = COUNT(*)
    FROM sys.indexes AS i
    LEFT JOIN sys.dm_db_index_usage_stats AS us
        ON us.object_id = i.object_id
       AND us.index_id = i.index_id
       AND us.database_id = DB_ID()
    WHERE i.type = 2
      AND i.is_primary_key = 0
      AND ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0) = 0
      AND OBJECTPROPERTY(i.object_id, N'IsUserTable') = 1;
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

SET @Score = CASE
    WHEN @ReadError = 1 THEN 0
    WHEN @EmptyTableCount = 0 AND @UnusedIndexCount = 0 THEN 3
    WHEN (@EmptyTableCount > 0 AND @UnusedIndexCount = 0)
      OR (@EmptyTableCount = 0 AND @UnusedIndexCount > 0) THEN 2
        WHEN @EmptyTableCount > 0 AND @UnusedIndexCount > 0 THEN 1
        ELSE 0
END;

SET @Finding = CONCAT(
    N'empty tables = ', @EmptyTableCount,
    N'; unused nonclustered indexes = ', @UnusedIndexCount,
    CASE WHEN @ReadError = 1 THEN N'; one or more catalog or usage DMV sources could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
