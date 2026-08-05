SET NOCOUNT ON;
-- Fail if any stored procedure/object contains a literal 'SELECT *'
SELECT CASE WHEN EXISTS(
    SELECT 1 FROM sys.sql_modules m
    WHERE m.definition LIKE '%SELECT %*%'
) THEN 'Failed' ELSE 'Passed' END AS Result;
