-- Checklist: Log/rowcount reconciliation captured per ETL run
-- Scope: DATABASE
-- Scoring: 0=No logging evidence found; 1=Logging tables exist by naming convention but lack explicit rowcount/reconciliation columns; 2=Logging tables with explicit rowcount/reconciliation columns detected (proxy evidence); 3=Fully verified compliance (reserved for cases where actual run logs are queryable, otherwise capped at 2)
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
        INSERT INTO #DbResults
        SELECT ''' + @DbName + N''',
               CASE
                   WHEN EXISTS (SELECT 1 FROM sys.tables t JOIN sys.columns c ON t.object_id = c.object_id
                                WHERE (t.name LIKE ''%log%'' OR t.name LIKE ''%reconcil%'' OR t.name LIKE ''%etl%'' OR t.name LIKE ''%load%'' OR t.name LIKE ''%sync%'')
                                   AND (c.name LIKE ''%row_count%'' OR c.name LIKE ''%processed_rows%'' OR c.name LIKE ''%source_rows%'' OR c.name LIKE ''%target_rows%'' OR c.name LIKE ''%record_count%''))
                   THEN 2
                   WHEN EXISTS (SELECT 1 FROM sys.tables t 
                                WHERE t.name LIKE ''%log%'' OR t.name LIKE ''%reconcil%'' OR t.name LIKE ''%etl%'' OR t.name LIKE ''%load%'' OR t.name LIKE ''%sync%'')
                   THEN 1
                   ELSE 0
               END;';
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
-- NOTE: This script provides automated evidence. Full compliance requires human review.