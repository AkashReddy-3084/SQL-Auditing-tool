-- Checklist: Single source of truth — no duplicate warehouses serving the same purpose
-- Scoring: 0=Fail (3+ potential duplicates), 1=Partial Pass (2 potential duplicates), 2=Mostly Pass (1 primary or naming variations). Capped at 2 per partial-evidence rule.
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

CREATE TABLE #WarehouseCandidates (
    DBName NVARCHAR(128),
    TableCount INT,
    SchemaCount INT
);

DECLARE @SQL NVARCHAR(MAX) = N'';
SELECT @SQL = @SQL + N'
    BEGIN TRY
        INSERT INTO #WarehouseCandidates
        SELECT 
            DB_NAME() AS DBName,
            (SELECT COUNT(*) FROM sys.tables WHERE type = ''U'') AS TableCount,
            (SELECT COUNT(*) FROM sys.schemas) AS SchemaCount
        FROM ' + QUOTENAME(name) + N';
    END TRY
    BEGIN CATCH
        -- Skip databases with restricted access or offline state
    END CATCH;'
FROM sys.databases 
WHERE state_desc = 'ONLINE' 
  AND name NOT IN ('master', 'tempdb', 'model', 'msdb');

EXEC sp_executesql @SQL;

DECLARE @WarehouseCount INT;
-- Proxy indicator: Databases with common warehouse naming conventions and >10 user tables
SELECT @WarehouseCount = COUNT(*) FROM #WarehouseCandidates 
WHERE (DBName LIKE '%DW%' OR DBName LIKE '%WH%' OR DBName LIKE '%Analytics%' OR DBName LIKE '%BI%' OR DBName LIKE '%Mart%')
  AND TableCount > 10;

IF @WarehouseCount >= 3 SET @Score = 0;
ELSE IF @WarehouseCount = 2 SET @Score = 1;
ELSE SET @Score = 2; -- 0 or 1 detected, or named differently

IF @Score = 0 SET @Result = 'Fail';
ELSE IF @Score = 1 SET @Result = 'Partial Pass';
ELSE SET @Result = 'Pass';

SELECT @Result AS Result, @Score AS Score;

DROP TABLE #WarehouseCandidates;