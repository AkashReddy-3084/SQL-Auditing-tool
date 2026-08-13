-- Checklist: Audit columns present where needed (created/modified, source, batch)
-- Scope: DATABASE
-- Scoring: 0 = 0% coverage, 1 = 1-24%, 2 = 25-74%, 3 = >=75% of user tables contain audit columns. NOTE: This script provides automated evidence. Full compliance requires human review.
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
        DECLARE @TotalTables INT = (SELECT COUNT(*) FROM sys.tables WHERE type = ''U'');
        DECLARE @TablesWithAudit INT = (SELECT COUNT(DISTINCT t.object_id) 
            FROM sys.tables t 
            JOIN sys.columns c ON t.object_id = c.object_id 
            WHERE t.type = ''U'' 
            AND (c.name LIKE ''created_%'' OR c.name LIKE ''modified_%'' OR c.name LIKE ''source_%'' OR c.name LIKE ''batch_%'' OR c.name LIKE ''audit_%'' OR c.name LIKE ''load_%'' OR c.name LIKE ''updated_%'' OR c.name LIKE ''inserted_%''));
        DECLARE @Pct FLOAT = CASE WHEN @TotalTables = 0 THEN 100 ELSE (@TablesWithAudit * 100.0 / @TotalTables) END;
        DECLARE @DbScore INT = CASE WHEN @Pct >= 75 THEN 3 WHEN @Pct >= 25 THEN 2 WHEN @Pct > 0 THEN 1 ELSE 0 END;
        INSERT INTO #DbResults VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore);';
        EXEC sp_executesql @Sql;
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