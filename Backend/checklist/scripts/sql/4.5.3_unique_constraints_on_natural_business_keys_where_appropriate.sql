SET NOCOUNT ON;
-- Check whether the database contains any unique constraints
SELECT CASE WHEN EXISTS(SELECT 1 FROM sys.objects o JOIN sys.indexes i ON i.object_id = o.object_id WHERE o.type = 'U' AND i.is_unique_constraint = 1) THEN 'Passed' ELSE 'NeedsReview' END AS Result;
