-- Checklist: Source-to-target lineage documented (ETL mappings)
-- Scope: DATABASE
-- Scoring: 0 = No lineage metadata found; 1 = Sparse lineage metadata (<25% of tables); 2 = Substantial lineage metadata (>=25% of tables). Capped at 2 as documentation requires human validation.
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
        DECLARE @TotalTables INT;
        DECLARE @LineageTables INT;
        SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE type = ''U'';
        SELECT @LineageTables = COUNT(DISTINCT t.object_id)
        FROM sys.tables t
        INNER JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.minor_id = 0
        WHERE ep.name LIKE ''%lineage%'' OR ep.name LIKE ''%source%'' OR ep.name LIKE ''%mapping%'' OR ep.name LIKE ''%etl%''
           OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%lineage%'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%source%'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%mapping%'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%etl%'';
        INSERT INTO #DbResults VALUES (@DbNameParam, 
            CASE 
                WHEN @TotalTables > 0 AND CAST(@LineageTables AS FLOAT) / @TotalTables >= 0.25 THEN 2
                WHEN @LineageTables > 0 THEN 1
                ELSE 0 
            END);';
        EXEC sp_executesql @Sql, N'@DbNameParam NVARCHAR(256)', @DbNameParam = @DbName;
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