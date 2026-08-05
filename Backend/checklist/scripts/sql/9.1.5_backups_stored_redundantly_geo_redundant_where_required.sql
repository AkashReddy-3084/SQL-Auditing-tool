SET NOCOUNT ON;
-- Check for a recent full database backup in last 7 days
IF EXISTS(
    SELECT 1 FROM msdb.dbo.backupset b WHERE b.database_name = DB_NAME() AND b.type = 'D' AND b.backup_finish_date > DATEADD(day,-7,GETDATE())
)
    SELECT 'Passed' AS Result;
ELSE
    SELECT 'Failed' AS Result;
