-- Checklist: Business/transformation logic encapsulated in stored procedures/functions (not ad-hoc scripts)
-- Scope: DATABASE
-- Scoring: 0 = No procedures/functions found; 1 = Procedures/functions exist but no transformation patterns; 2 = Transformation patterns found (proxy evidence); 3 = Extensive encapsulation (capped at 2 due to proxy nature)
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
        DECLARE @ProcCount INT, @FuncCount INT, @TransformCount INT;
        SELECT @ProcCount = COUNT(*) FROM sys.objects WHERE type = ''P'' AND is_ms_shipped = 0;
        SELECT @FuncCount = COUNT(*) FROM sys.objects WHERE type IN (''FN'', ''IF'', ''TF'') AND is_ms_shipped = 0;
        SELECT @TransformCount = COUNT(*) FROM sys.objects o
        JOIN sys.sql_modules m ON o.object_id = m.object_id
        WHERE o.is_ms_shipped = 0 AND o.type IN (''P'', ''FN'', ''IF'', ''TF'')
        AND (o.name LIKE ''usp_%'' OR o.name LIKE ''fn_%'' OR o.name LIKE ''etl_%'' OR o.name LIKE ''transform_%'' OR o.name LIKE ''load_%'' OR o.name LIKE ''calc_%'' OR o.name LIKE ''process_%'');
        
        INSERT INTO #DbResults VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', 
            CASE 
                WHEN (@ProcCount + @FuncCount) = 0 THEN 0
                WHEN @TransformCount = 0 THEN 1
                ELSE 2 
            END);
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
-- NOTE: This script provides automated evidence. Full compliance requires human review.
-- NOTE: Max score capped at 2 because ad-hoc script usage cannot be fully verified via metadata alone.