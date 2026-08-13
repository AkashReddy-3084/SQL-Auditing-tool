```sql
-- Checklist: Transparent Data Encryption (TDE) enabled for encryption at rest
-- Scope: DATABASE
-- Scoring: 
-- 3 = All user databases have TDE enabled (Fully Compliant)
-- 1 = Some user databases have TDE enabled, but not all (Partial Evidence / Fail)
-- 0 = No user databases have TDE enabled (Non-Compliant)
-- NOTE: Score 2 is not used because TDE is direct evidence; partial compliance results in a Fail per worst-case aggregation rules.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @TotalDbs INT = 0;
DECLARE @EncryptedDbs INT = 0;

-- Create temp table to collect per-database results
CREATE TABLE #DbResults (DbName NVARCHAR(256), IsEncrypted BIT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        -- Check is_encrypted in sys.databases for the current database
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        SELECT is_encrypted FROM sys.databases WHERE name = ''' + REPLACE(@DbName, '''', '''''') + '''';

        INSERT INTO #DbResults
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        -- If we cannot access the database or an error occurs, assume not encrypted (Fail)
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Aggregate results
SELECT @TotalDbs = COUNT(*), @EncryptedDbs = SUM(IsEncrypted) FROM #DbResults;

-- Determine Score based on aggregation
IF @TotalDbs = 0
    SET @Score = 3; -- No user databases to check (Vacuously true)
ELSE IF @EncryptedDbs = @TotalDbs
    SET @Score = 3; -- All user databases are encrypted
ELSE IF @EncryptedDbs > 0
    SET @Score = 1; -- Partial encryption (Fail because not all are encrypted)
ELSE
    SET @Score = 0; -- No user databases are encrypted

-- Derive Result from Score
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;
```