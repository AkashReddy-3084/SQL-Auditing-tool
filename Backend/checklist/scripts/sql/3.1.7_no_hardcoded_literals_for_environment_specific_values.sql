SET NOCOUNT ON;
-- Heuristic: search code for common credential keywords (may produce false positives)
SELECT CASE WHEN EXISTS(
    SELECT 1 FROM sys.sql_modules m WHERE m.definition LIKE '%password=%' OR m.definition LIKE '%pwd=%' OR m.definition LIKE '%credential%'
) THEN 'NeedsReview' ELSE 'Passed' END AS Result;
