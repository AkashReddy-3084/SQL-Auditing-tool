-- Checklist: Business definitions/rules documented and current
-- Scope: DATABASE
-- Scoring: 0=0% coverage, 1=1-19%, 2=20-49%, 3=>=50%. NOTE: This script provides automated evidence. Full compliance requires human review.
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
        DECLARE @DocTables INT;
        SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0;
        SELECT @DocTables = COUNT(DISTINCT t.object_id) FROM sys.tables t
        INNER JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.minor_id = 0
        WHERE t.is_ms_shipped = 0 AND (ep.name LIKE ''%Description%'' OR ep.name LIKE ''%Rule%'' OR ep.name LIKE ''%Definition%'');
        DECLARE @Coverage DECIMAL(5,2) = CASE WHEN @TotalTables = 0 THEN 100 ELSE (@DocTables * 100.0 / @TotalTables) END;
        DECLARE @DbScore INT = CASE 
            WHEN @Coverage >= 50 THEN 3
            WHEN @Coverage >= 20 THEN 2
            WHEN @Coverage > 0 THEN 1
            ELSE 0
        END;
        INSERT INTO #DbResults VALUES (''' + @DbName + ''', @DbScore);';
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