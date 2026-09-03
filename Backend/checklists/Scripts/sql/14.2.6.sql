-- Checklist: Fill factor tuned for volatile tables where needed
-- Scope: DATABASE
-- Scoring: 3 = at least 75% of user indexes have a non-default fill factor; 2 = 50%-74%; 1 = greater than 0% but below 50%; 0 = indexes exist but none are tuned, or evidence is unavailable
-- NOTE: Automated evidence shows configured fill factors; whether a specific table is volatile and needs tuning requires human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Fill-factor evidence unavailable';
DECLARE @IndexCount INT = 0;
DECLARE @TunedIndexCount INT = 0;
DECLARE @ReadError BIT = 0;
DECLARE @TunedPercent DECIMAL(6, 2) = 0.00;

BEGIN TRY
    SELECT
        @IndexCount = COUNT(*),
        @TunedIndexCount = ISNULL(SUM(CASE WHEN i.fill_factor NOT IN (0, 100) THEN 1 ELSE 0 END), 0)
    FROM sys.indexes AS i
    INNER JOIN sys.objects AS o ON o.object_id = i.object_id
    WHERE o.is_ms_shipped = 0
      AND i.index_id > 0;
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

SET @TunedPercent = CASE
    WHEN @IndexCount = 0 THEN 0.00
    ELSE CONVERT(DECIMAL(6, 2), 100.0 * @TunedIndexCount / NULLIF(@IndexCount, 0))
END;

SET @Score = CASE
    WHEN @ReadError = 1 THEN 0
    WHEN @IndexCount = 0 THEN 2
    WHEN @TunedPercent >= 75.00 THEN 3
    WHEN @TunedPercent >= 50.00 THEN 2
    WHEN @TunedIndexCount > 0 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'user indexes = ', @IndexCount,
    N'; indexes with non-default fill factor = ', @TunedIndexCount,
    N'; tuned percentage = ', @TunedPercent, N'%',
    CASE WHEN @ReadError = 1 THEN N'; index metadata could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
