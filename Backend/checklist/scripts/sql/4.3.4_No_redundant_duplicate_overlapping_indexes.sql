-- Checklist: No redundant/duplicate/overlapping indexes
-- Scope: DATABASE
-- Scoring: 3 = No overlapping indexes found; 2 = 1-4 overlapping index pairs; 1 = 5-10 overlapping index pairs; 0 = >10 overlapping index pairs
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
DECLARE @OverlapCount INT = 0;
WITH IndexKeys AS (
    SELECT
        t.name AS TableName,
        i.name AS IndexName,
        i.index_id,
        STUFF((
            SELECT '','' + c.name
            FROM sys.index_columns ic
            JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
            WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
            ORDER BY ic.key_ordinal
            FOR XML PATH(''), TYPE).value(''.'',''NVARCHAR(MAX)''), 1, 1, ''''
    ) AS KeyColumns
    FROM sys.tables t
    JOIN sys.indexes i ON t.object_id = i.object_id
    WHERE i.type = 2
      AND i.is_hypothetical = 0
)
SELECT @OverlapCount = COUNT(*)
FROM IndexKeys a
JOIN IndexKeys b ON a.TableName = b.TableName AND a.index_id < b.index_id
WHERE a.KeyColumns LIKE b.KeyColumns + '',''%'' OR b.KeyColumns LIKE a.KeyColumns + '',''%'' OR a.KeyColumns = b.KeyColumns;

DECLARE @DbScore INT;
SET @DbScore = CASE
    WHEN @OverlapCount = 0 THEN 3
    WHEN @OverlapCount BETWEEN 1 AND 4 THEN 2
    WHEN @OverlapCount BETWEEN 5 AND 10 THEN 1
    ELSE 0
END;
INSERT INTO #DbResults VALUES (@DB, @DbScore);';
        
        EXEC sp_executesql @Sql, N'@DB NVARCHAR(256)', @DB = @DbName;
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