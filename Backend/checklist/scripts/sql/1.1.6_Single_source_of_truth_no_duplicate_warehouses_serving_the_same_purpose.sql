-- Checklist: Single source of truth — no duplicate warehouses serving the same purpose
-- Scope: DATABASE
-- Scoring: 0=High duplicate risk (identical structure/metadata), 1=Moderate risk (structural overlap), 2=Low risk (distinct structures, proxy evidence), 3=Fully verified (single warehouse DB or explicit unique purpose metadata)
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(256),
    TableCount INT,
    SchemaCount INT,
    Purpose NVARCHAR(256),
    IsWarehouse BIT
);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        SELECT
            DB_NAME() AS DbName,
            (SELECT COUNT(*) FROM sys.tables WHERE type = ''U'') AS TableCount,
            (SELECT COUNT(*) FROM sys.schemas) AS SchemaCount,
            (SELECT CONVERT(NVARCHAR(256), value) FROM sys.extended_properties WHERE name = ''Purpose'' AND class = 0) AS Purpose,
            CASE WHEN LOWER(DB_NAME()) LIKE ''%warehouse%'' OR LOWER(DB_NAME()) LIKE ''%dw%'' OR LOWER(DB_NAME()) LIKE ''%data_warehouse%'' THEN 1 ELSE 0 END AS IsWarehouse;
        ';
        INSERT INTO #DbResults EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0, 0, NULL, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Evaluation Logic
DECLARE @WarehouseCount INT = (SELECT COUNT(*) FROM #DbResults WHERE IsWarehouse = 1);
DECLARE @DuplicateCount INT = 0;

IF @WarehouseCount <= 1
BEGIN
    SET @Score = 3;
END
ELSE
BEGIN
    -- Check for exact structural duplicates among warehouses
    SELECT @DuplicateCount = COUNT(*) FROM (
        SELECT TableCount, SchemaCount, Purpose
        FROM #DbResults
        WHERE IsWarehouse = 1
        GROUP BY TableCount, SchemaCount, Purpose
        HAVING COUNT(*) > 1
    ) AS Dups;

    IF @DuplicateCount > 0
        SET @Score = 0;
    ELSE
    BEGIN
        -- Check for partial overlap (similar table counts within 20%)
        DECLARE @OverlapCount INT = 0;
        SELECT @OverlapCount = COUNT(*) FROM (
            SELECT r1.DbName, r2.DbName
            FROM #DbResults r1
            JOIN #DbResults r2 ON r1.DbName < r2.DbName
            WHERE r1.IsWarehouse = 1 AND r2.IsWarehouse = 1
              AND ABS(r1.TableCount - r2.TableCount) <= CAST(r1.TableCount * 0.2 AS INT)
        ) AS Overlaps;

        IF @OverlapCount > 0
            SET @Score = 1;
        ELSE
            SET @Score = 2;
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;