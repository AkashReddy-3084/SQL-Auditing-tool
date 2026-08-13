-- Checklist: Historical/archival strategy defined for the DW
-- Scope: DATABASE
-- Scoring: 0=No evidence, 1=Minimal (1 indicator), 2=Good/Strong (2+ indicators). Capped at 2 due to proxy evidence requiring human validation.
SET NOCOUNT ON;
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DbScore INT;

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
        DECLARE @Indicators INT = 0;
        
        -- Check 1: Archive/History schemas
        IF EXISTS (SELECT 1 FROM sys.schemas WHERE name LIKE ''%arch%'' OR name LIKE ''%hist%'' OR name LIKE ''%history%'')
            SET @Indicators += 1;
            
        -- Check 2: Archive/History tables
        IF EXISTS (SELECT 1 FROM sys.tables WHERE name LIKE ''%arch%'' OR name LIKE ''%hist%'' OR name LIKE ''%history%'')
            SET @Indicators += 1;
            
        -- Check 3: Partition functions/schemes (common for DW archival)
        IF EXISTS (SELECT 1 FROM sys.partition_functions) AND EXISTS (SELECT 1 FROM sys.partition_schemes)
            SET @Indicators += 1;
            
        -- Check 4: Archival jobs (on-prem/MI only)
        IF DB_ID(''msdb'') IS NOT NULL
        BEGIN
            IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name LIKE ''%arch%'' OR name LIKE ''%hist%'' OR name LIKE ''%purge%'')
                SET @Indicators += 1;
        END
        
        -- Check 5: Archival procedures
        IF EXISTS (SELECT 1 FROM sys.procedures WHERE name LIKE ''%arch%'' OR name LIKE ''%hist%'' OR name LIKE ''%purge%'')
            SET @Indicators += 1;

        SELECT @DbScore = CASE WHEN @Indicators = 0 THEN 0 WHEN @Indicators = 1 THEN 1 ELSE 2 END;
        ';
        EXEC sp_executesql @Sql, N'@DbScore INT OUTPUT', @DbScore = @DbScore OUTPUT;
        INSERT INTO #DbResults VALUES (@DbName, @DbScore);
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