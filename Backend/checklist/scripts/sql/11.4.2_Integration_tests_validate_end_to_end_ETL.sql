-- Checklist: Integration tests validate end-to-end ETL
-- Scope: DATABASE
-- Scoring: 0=No test objects found; 1=1-2 objects with test keywords; 2=3-5 objects with ETL integration test keywords; 3=>5 objects with comprehensive ETL validation keywords. NOTE: This script provides automated evidence. Full compliance requires human review.
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
        DECLARE @TestCount INT = 0;
        SELECT @TestCount = COUNT(*) FROM sys.procedures p
        CROSS APPLY (SELECT definition FROM sys.sql_modules m WHERE m.object_id = p.object_id) d
        WHERE p.name LIKE ''%test%'' OR p.name LIKE ''%e2e%'' OR p.name LIKE ''%integration%'' OR p.name LIKE ''%validate%''
           OR d.definition LIKE ''%integration test%'' OR d.definition LIKE ''%end-to-end%'' OR d.definition LIKE ''%validate ETL%'' OR d.definition LIKE ''%e2e test%'';
        
        INSERT INTO #DbResults (DbName, DbScore) VALUES (@Db, 
            CASE 
                WHEN @TestCount = 0 THEN 0
                WHEN @TestCount BETWEEN 1 AND 2 THEN 1
                WHEN @TestCount BETWEEN 3 AND 5 THEN 2
                ELSE 3
            END);
        ';
        EXEC sp_executesql @Sql, N'@Db NVARCHAR(256)', @Db = @DbName;
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