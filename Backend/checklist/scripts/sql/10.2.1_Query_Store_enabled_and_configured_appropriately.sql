SET NOCOUNT ON;
-- Check for Query Store presence (SQL Server/Managed Instance)
IF EXISTS (SELECT 1 FROM sys.database_query_store_options)
    SELECT 'Passed' AS Result;
ELSE
    SELECT 'Failed' AS Result;
