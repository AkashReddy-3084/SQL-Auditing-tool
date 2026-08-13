SET NOCOUNT ON;

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT ' + QUOTENAME(@DbName) + N' AS DbName,
CASE
    WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.tables t JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas s ON t.schema_id = s.schema_id WHERE t.name LIKE ''%dq%'' OR t.name LIKE ''%quality%'' OR t.name LIKE ''%audit%'' OR t.name LIKE ''%log%'')
    AND EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.columns c JOIN ' + QUOTENAME(@DbName) + N'.sys.tables t ON c.object_id = t.object_id WHERE t.name LIKE ''%dq%'' OR t.name LIKE ''%quality%'' OR t.name LIKE ''%audit%'' OR t.name LIKE ''%log%'' AND (c.name LIKE ''%date%'' OR c.name LIKE ''%timestamp%'' OR c.name LIKE ''%count%'' OR c.name LIKE ''%score%''))
    AND (SELECT ISNULL(SUM(p.rows),0) FROM ' + QUOTENAME(@DbName) + N'.sys.partitions p JOIN ' + QUOTENAME(@DbName) + N'.sys.tables t ON p.object_id = t.object_id WHERE (t.name LIKE ''%dq%'' OR t.name LIKE ''%quality%'' OR t.name LIKE ''%audit%'' OR t.name LIKE ''%log%'') AND p.index_id < 2 AND p.partition_number = 1) > 100
    THEN 3
    WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.tables t JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas s ON t.schema_id = s.schema_id WHERE t.name LIKE ''%dq%'' OR t.name LIKE ''%quality%'' OR t.name LIKE ''%audit%'' OR t.name LIKE ''%log%'')
    AND EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.columns c JOIN ' + QUOTENAME(@DbName) + N'.sys.tables t ON c.object_id = t.object_id WHERE t.name LIKE ''%dq%'' OR t.name LIKE ''%quality%'' OR t.name LIKE ''%audit%'' OR t.name LIKE ''%log%'' AND (c.name LIKE ''%date%'' OR c.name LIKE ''%timestamp%'' OR c.name LIKE ''%count%'' OR c.name LIKE ''%score%''))
    THEN 2
    WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.tables t JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas s ON t.schema_id = s.schema_id WHERE t.name LIKE ''%dq%'' OR t.name LIKE ''%quality%'' OR t.name LIKE ''%audit%'' OR t.name LIKE ''%log%'')
    THEN 1
    ELSE 0
END AS DbScore';
        INSERT INTO #DbResults (DbName, DbScore) EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        -- Gracefully handle inaccessible databases by assigning a score of 0
        INSERT INTO #DbResults (DbName, DbScore) VALUES (@DbName, 0);
    END CATCH
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Aggregate results: worst-case (MIN) across all user databases
SELECT @Score = ISNULL(MIN(DbScore), 0) FROM #DbResults;

-- Determine Pass/Fail based on scoring logic
SET @Result = CASE WHEN @Score = 3 THEN 'Pass' ELSE 'Fail' END;

-- Cleanup temporary table
DROP TABLE #DbResults;

-- Required output format
SELECT @Result AS Result, @Score AS Score;