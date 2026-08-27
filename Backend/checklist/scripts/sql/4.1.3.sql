-- Checklist: Data types appropriate and right-sized (no oversized varchar, correct numeric precision)
-- Scope: DATABASE
-- Scoring: 2 = no oversized columns; 1 = oversized columns exist; 0 = no user columns or metadata unavailable. Numeric precision and workload appropriateness require human review.
-- NOTE: Automated evidence only; numeric precision and workload appropriateness require human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Data type metadata could not be evaluated';
DECLARE @TotalColumns INT = 0;
DECLARE @Oversized INT = 0;

BEGIN TRY
    SELECT @TotalColumns = COUNT(*),
           @Oversized = ISNULL(SUM(CASE WHEN c.max_length = -1 OR (t.name IN ('varchar', 'nvarchar', 'char', 'nchar') AND c.max_length >= 4000) THEN 1 ELSE 0 END), 0)
    FROM sys.columns AS c
    JOIN sys.types AS t ON c.user_type_id = t.user_type_id
    WHERE OBJECTPROPERTY(c.object_id, 'IsUserTable') = 1;

    SET @Score = CASE WHEN @TotalColumns = 0 THEN 0 WHEN @Oversized = 0 THEN 2 ELSE 1 END;
    SET @Finding = N'total_cols=' + CONVERT(NVARCHAR(20), @TotalColumns) + N', oversized=' + CONVERT(NVARCHAR(20), @Oversized);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read data type metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;