-- Checklist: Auto-create statistics enabled where appropriate
-- Scope: DATABASE
-- Scoring: 3 = Enabled (ON), 0 = Disabled (OFF).
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @DbScore INT;
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
        -- Check the setting in the context of the specific database
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        SELECT @DbScore = CASE WHEN is_auto_create_stats_on = 1 THEN 3 ELSE 0 END
        FROM sys.databases
        WHERE name = DB_NAME();
        ';
        
        EXEC sp_executesql @Sql, N'@DbScore INT OUTPUT', @DbScore OUTPUT;
        
        INSERT INTO #DbResults VALUES (@DbName, @DbScore);
    END TRY
    BEGIN CATCH
        -- If we cannot access the database or check the setting, treat as Fail (0)
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