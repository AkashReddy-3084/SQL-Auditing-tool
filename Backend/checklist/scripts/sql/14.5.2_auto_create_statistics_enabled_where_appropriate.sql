SET NOCOUNT ON;
-- Check auto-update stats database option
SELECT CASE WHEN DATABASEPROPERTYEX(DB_NAME(),'IsAutoUpdateStatistics') = 1 THEN 'Passed' ELSE 'Failed' END AS Result;
