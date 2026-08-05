SET NOCOUNT ON;
-- Check whether the database contains any foreign keys
SELECT CASE WHEN EXISTS(SELECT 1 FROM sys.foreign_keys) THEN 'Passed' ELSE 'NeedsReview' END AS Result;
