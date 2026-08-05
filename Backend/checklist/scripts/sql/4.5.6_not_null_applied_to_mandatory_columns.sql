SET NOCOUNT ON;
-- Check whether any nullable columns exist on user tables
SELECT CASE WHEN EXISTS(
    SELECT 1 FROM sys.columns c JOIN sys.tables t ON t.object_id = c.object_id WHERE t.is_ms_shipped = 0 AND c.is_nullable = 1
) THEN 'NeedsReview' ELSE 'Passed' END AS Result;
