SET NOCOUNT ON;
-- Check whether the database contains any check constraints
SELECT CASE WHEN EXISTS(SELECT 1 FROM sys.check_constraints) THEN 'Passed' ELSE 'NeedsReview' END AS Result;
