SET NOCOUNT ON;
-- Check Transparent Data Encryption enabled for current database
SELECT CASE WHEN EXISTS(
    SELECT 1 FROM sys.dm_database_encryption_keys dek WHERE dek.database_id = DB_ID() AND dek.encryption_state = 3
) THEN 'Passed' ELSE 'Failed' END AS Result;
