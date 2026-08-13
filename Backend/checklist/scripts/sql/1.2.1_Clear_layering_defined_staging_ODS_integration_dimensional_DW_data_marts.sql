-- Checklist: Clear layering defined (staging → ODS/integration → dimensional DW → data marts)
-- Scope: DATABASE
-- Scoring: 0=No evidence, 1=1-2 layers, 2=3 layers, 3=All 4 layers found
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @LayerCount INT;

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
        -- Check for 4 distinct layer types: Staging, ODS, DW, Mart
        -- We look at both Schemas (preferred) and Tables (fallback for flat schemas)
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        SELECT @LayerCount = COUNT(DISTINCT LayerType) FROM (
            -- Check Schemas
            SELECT ''Staging'' AS LayerType FROM sys.schemas WHERE name LIKE ''stg%'' OR name LIKE ''landing%'' OR name LIKE ''raw%''
            UNION ALL
            SELECT ''ODS'' FROM sys.schemas WHERE name LIKE ''ods%'' OR name LIKE ''integration%''
            UNION ALL
            SELECT ''DW'' FROM sys.schemas WHERE name LIKE ''dim%'' OR name LIKE ''fact%'' OR name LIKE ''dw%''
            UNION ALL
            SELECT ''Mart'' FROM sys.schemas WHERE name LIKE ''mart%'' OR name LIKE ''report%'' OR name LIKE ''app%''
            -- Check Tables (in case schemas are not used)
            UNION ALL
            SELECT ''Staging'' FROM sys.tables WHERE name LIKE ''stg%'' OR name LIKE ''landing%''
            UNION ALL
            SELECT ''ODS'' FROM sys.tables WHERE name LIKE ''ods%''
            UNION ALL
            SELECT ''DW'' FROM sys.tables WHERE name LIKE ''dim%'' OR name LIKE ''fact%''
            UNION ALL
            SELECT ''Mart'' FROM sys.tables WHERE name LIKE ''mart%''
        ) AS Layers;';

        EXEC sp_executesql @Sql, N'@LayerCount INT OUTPUT', @LayerCount OUTPUT;

        -- Map Layer Count to Score
        SET @Score = CASE
            WHEN @LayerCount >= 4 THEN 3
            WHEN @LayerCount >= 3 THEN 2
            WHEN @LayerCount >= 1 THEN 1
            ELSE 0
        END;

        INSERT INTO #DbResults VALUES (@DbName, @Score);
    END TRY
    BEGIN CATCH
        -- If we cannot access the DB, assume 0
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