SET NOCOUNT ON;
-- Passed when every user table has a primary key
SELECT CASE WHEN EXISTS(
    SELECT 1 FROM sys.tables t
    WHERE t.is_ms_shipped = 0
    AND NOT EXISTS(
        SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.is_primary_key = 1
    )
) THEN 'Failed' ELSE 'Passed' END AS Result;
