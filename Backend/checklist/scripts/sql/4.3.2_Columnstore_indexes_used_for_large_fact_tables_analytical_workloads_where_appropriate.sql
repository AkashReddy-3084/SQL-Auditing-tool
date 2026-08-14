-- Checklist: Columnstore indexes used for large fact tables / analytical workloads where appropriate
-- Scope: DATABASE
-- Scoring: 0=No columnstore indexes found; 1=Columnstore indexes exist but only on small tables (<1M rows); 2=Columnstore indexes on some large fact tables (>=1M rows); 3=Columnstore indexes on all large fact tables matching analytical naming patterns.
-- NOTE: This script provides automated evidence. Full compliance requires human review.
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
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @HasCS INT = 0;
        DECLARE @TotalLargeFact INT = 0;
        DECLARE @LargeFactWithCS INT = 0;

        SELECT @HasCS = COUNT(DISTINCT i.object_id) 
        FROM sys.indexes i 
        JOIN sys.tables t ON i.object_id = t.object_id 
        WHERE i.type IN (5, 6);

        SELECT @TotalLargeFact = COUNT(DISTINCT t.object_id) 
        FROM sys.tables t 
        JOIN (SELECT object_id, SUM(rows) as total_rows FROM sys.partitions WHERE index_id IN (0, 1) GROUP BY object_id) p 
          ON t.object_id = p.object_id 
        WHERE t.type = ''U'' 
          AND p.total_rows >= 1000000 
          AND (t.name LIKE ''%fact%'' OR t.name LIKE ''%transaction%'' OR t.name LIKE ''%event%'' OR t.name LIKE ''%sales%'');

        SELECT @LargeFactWithCS = COUNT(DISTINCT t.object_id) 
        FROM sys.tables t 
        JOIN sys.indexes i ON t.object_id = i.object_id 
        JOIN (SELECT object_id, SUM(rows) as total_rows FROM sys.partitions WHERE index_id IN (0, 1) GROUP BY object_id) p 
          ON t.object_id = p.object_id 
        WHERE t.type = ''U'' 
          AND i.type IN (5, 6) 
          AND p.total_rows >= 1000000 
          AND (t.name LIKE ''%fact%'' OR t.name LIKE ''%transaction%'' OR t.name LIKE ''%event%'' OR t.name LIKE ''%sales%'');

        INSERT INTO #DbResults VALUES (''' + @DbName + ''', 
            CASE 
                WHEN @TotalLargeFact = 0 THEN 3
                WHEN @HasCS = 0 THEN 0
                WHEN @LargeFactWithCS = 0 THEN 1
                WHEN @LargeFactWithCS < @TotalLargeFact THEN 2
                ELSE 3
            END);
        ';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;