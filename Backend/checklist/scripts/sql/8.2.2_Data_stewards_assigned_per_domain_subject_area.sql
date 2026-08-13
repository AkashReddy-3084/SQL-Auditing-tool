-- Checklist: Data stewards assigned per domain/subject area
-- Scope: DATABASE
-- Scoring: 0=No steward metadata found; 1=Steward metadata found on <25% of schemas; 2=Steward metadata found on >=25% of schemas (proxy evidence); 3=Not achievable (max capped at 2 as actual steward assignments require human verification)
-- NOTE: This script provides automated evidence. Full compliance requires human review.
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
        DECLARE @TotalSchemas INT;
        DECLARE @StewardSchemas INT;
        SELECT @TotalSchemas = COUNT(*) FROM sys.schemas WHERE is_ms_shipped = 0;
        SELECT @StewardSchemas = COUNT(DISTINCT major_id)
        FROM sys.extended_properties
        WHERE class = 4
          AND (name LIKE ''%steward%'' OR name LIKE ''%owner%'' OR name LIKE ''%domain%'')
          AND major_id IN (SELECT schema_id FROM sys.schemas WHERE is_ms_shipped = 0);

        DECLARE @DbScore INT = 0;
        IF @TotalSchemas = 0 SET @DbScore = 0;
        ELSE IF @StewardSchemas = 0 SET @DbScore = 0;
        ELSE IF (@StewardSchemas * 100.0 / @TotalSchemas) < 25 SET @DbScore = 1;
        ELSE SET @DbScore = 2;

        INSERT INTO #DbResults VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore);';
        EXEC(@Sql);
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