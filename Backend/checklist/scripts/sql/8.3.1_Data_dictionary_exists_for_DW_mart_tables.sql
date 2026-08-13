-- Checklist: Data dictionary exists for DW/mart tables
-- Scope: DATABASE
-- Scoring: 0=0% coverage, 1=1-24%, 2=25-74%, 3=75-100% of DW/mart tables have MS_Description extended properties.
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
DECLARE @TotalTables INT = 0;
DECLARE @DocTables INT = 0;
SELECT @TotalTables = COUNT(*) FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE (s.name LIKE ''%dw%'' OR s.name LIKE ''%mart%'' OR s.name LIKE ''%warehouse%'');
SELECT @DocTables = COUNT(*) FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE (s.name LIKE ''%dw%'' OR s.name LIKE ''%mart%'' OR s.name LIKE ''%warehouse%'') AND EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE ep.major_id = t.object_id AND ep.minor_id = 0 AND ep.name = ''MS_Description'');
DECLARE @Pct FLOAT = CASE WHEN @TotalTables = 0 THEN 100 ELSE CAST(@DocTables AS FLOAT) / @TotalTables * 100 END;
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