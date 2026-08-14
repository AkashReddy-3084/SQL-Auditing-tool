-- Checklist: Always Encrypted used for highly sensitive columns where required
-- Scope: DATABASE
-- Scoring: 0=No encrypted columns found; 1=1-5 encrypted columns; 2=6-50 encrypted columns; 3=>50 encrypted columns.
-- NOTE: This script provides automated evidence. Full compliance requires human review to verify that all highly sensitive columns are actually encrypted.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
-- Create temp table to collect per-database results
CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @EncCount INT = 0;
        SELECT @EncCount = COUNT(*) FROM sys.columns WHERE is_encrypted = 1;
        INSERT INTO #DbResults (DbName, DbScore) VALUES (@DbName, CASE 
            WHEN @EncCount = 0 THEN 0
            WHEN @EncCount BETWEEN 1 AND 5 THEN 1
            WHEN @EncCount BETWEEN 6 AND 50 THEN 2
            ELSE 3
        END);';
        EXEC sp_executesql @Sql, N'@DbName NVARCHAR(256)', @DbName = @DbName;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Aggregate: worst-case score across all databases
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;