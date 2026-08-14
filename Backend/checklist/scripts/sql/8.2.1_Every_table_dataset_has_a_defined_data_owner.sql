-- Checklist: Every table/dataset has a defined data owner
-- Scope: DATABASE
-- Scoring: 0=0% tables have owner metadata, 1=1-49%, 2=50-100%, 3=Capped at 2 (proxy evidence requires human validation of actual values)
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
        DECLARE @TablesWithOwner INT;
        DECLARE @Pct FLOAT;
        DECLARE @DbScore INT;

        SELECT @TotalTables = COUNT(*) FROM sys.tables;
        SELECT @TablesWithOwner = COUNT(DISTINCT t.object_id)
        FROM sys.tables t
        INNER JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.minor_id = 0
        WHERE ep.name LIKE ''%owner%'' OR ep.name LIKE ''%steward%'' OR ep.name LIKE ''%contact%'' OR ep.name LIKE ''%DataOwner%'';

        SET @Pct = CASE WHEN @TotalTables = 0 THEN 100.0 ELSE (@TablesWithOwner * 100.0) / @TotalTables END;

        SET @DbScore = CASE
            WHEN @Pct >= 50 THEN 2
            WHEN @Pct >= 1 THEN 1
            ELSE 0
        END;

        INSERT INTO #DbResults VALUES (@DbName, @DbScore);
        ';
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
-- NOTE: This script provides automated evidence. Full compliance requires human review.