SET NOCOUNT ON;
-- Check whether SQL Agent jobs exist for this DB (requires msdb access)
SELECT CASE WHEN EXISTS(SELECT 1 FROM msdb.dbo.sysjobs) THEN 'Passed' ELSE 'NeedsReview' END AS Result;
