SET NOCOUNT ON;
-- Check whether force encryption is enabled at the server level
SELECT CASE WHEN EXISTS(
    SELECT 1 FROM sys.configurations WHERE name LIKE '%encryption%' AND convert(int, value_in_use) = 1
) THEN 'Passed' ELSE 'NeedsReview' END AS Result;
