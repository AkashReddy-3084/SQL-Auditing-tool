SET NOCOUNT ON;
-- Check whether any masked columns exist
SELECT CASE WHEN EXISTS(SELECT 1 FROM sys.masked_columns) THEN 'Passed' ELSE 'NeedsReview' END AS Result;
