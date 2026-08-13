-- Checklist: DQ rules codified (config-driven or reusable procedures), not ad-hoc manual checks
-- Scope: DATABASE
-- Scoring: 0=No DQ objects found, 1=Minimal/ad-hoc DQ objects, 2=Multiple DQ procs/tables with config/reusable patterns, 3=Fully automated verification (not achievable via proxy, capped at 2)
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
        -- Safely escape single quotes in database name for string literal insertion
        DECLARE @SafeDbName NVARCHAR(256) = REPLACE(@DbName, '''', '''''');
        
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        SET NOCOUNT ON;
        DECLARE @ProcCount INT = 0;
        DECLARE @TableCount INT = 0;
        DECLARE @ConfigRefCount INT = 0;

        SELECT @ProcCount = COUNT(*) FROM sys.procedures p
        WHERE p.name LIKE ''DQ_%'' OR p.name LIKE ''Quality_%'' OR p.name LIKE ''Validate_%'' OR p.name LIKE ''Check_%'';

        SELECT @TableCount = COUNT(*) FROM sys.tables t
        WHERE t.name LIKE ''%Rule%'' OR t.name LIKE ''%Config%'' OR t.name LIKE ''%DQ%'' OR t.name LIKE ''%Quality%'';

        SELECT @ConfigRefCount = COUNT(*) FROM sys.sql_modules m
        JOIN sys.procedures p ON m.object_id = p.object_id
        WHERE m.definition LIKE ''%Rule%'' COLLATE Latin1_General_CI_AS 
           OR m.definition LIKE ''%Config%'' COLLATE Latin1_General_CI_AS 
           OR m.definition LIKE ''%DQ%'' COLLATE Latin1_General_CI_AS;

        DECLARE @DbScore INT = 0;
        IF @ProcCount = 0 AND @TableCount = 0 SET @DbScore = 0;
        ELSE IF @ProcCount <= 2 AND @TableCount <= 1 SET @DbScore = 1;
        ELSE IF @ProcCount >= 3 OR @ConfigRefCount >= 2 SET @DbScore = 2;
        ELSE SET @DbScore = 1;

        INSERT INTO #DbResults VALUES (''' + @SafeDbName + ''', @DbScore);
        ';
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