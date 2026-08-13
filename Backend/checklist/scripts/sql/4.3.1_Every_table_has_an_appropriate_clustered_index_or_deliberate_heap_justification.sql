-- Checklist: Every table has an appropriate clustered index (or deliberate heap justification)
-- Scope: DATABASE
-- Scoring: 3=0 heaps, 2=1-5 heaps, 1=6-20 heaps, 0=>20 heaps
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
        DECLARE @HeapCount INT;
        SELECT @HeapCount = COUNT(*) FROM sys.tables t
        LEFT JOIN sys.indexes i ON t.object_id = i.object_id AND i.type = 1
        WHERE i.object_id IS NULL AND t.type = ''U'';
        INSERT INTO #DbResults VALUES (@DbName, CASE 
            WHEN @HeapCount = 0 THEN 3
            WHEN @HeapCount BETWEEN 1 AND 5 THEN 2
            WHEN @HeapCount BETWEEN 6 AND 20 THEN 1
            ELSE 0 
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
SET @Result = CASE WHEN @Score = 3 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;