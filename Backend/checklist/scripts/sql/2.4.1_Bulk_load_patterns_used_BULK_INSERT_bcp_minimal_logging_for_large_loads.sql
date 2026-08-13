-- Checklist: Bulk load patterns used (BULK INSERT / bcp / minimal logging) for large loads
-- Scope: DATABASE
-- Scoring: 0=No patterns found; 1=Patterns found but sparse/incomplete; 2=Strong evidence of bulk load patterns; 3=Reserved (capped at 2 for proxy evidence). Worst-case across DBs.
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
        DECLARE @DbScore INT = 0;
        DECLARE @MatchCount INT = 0;
        
        SELECT @MatchCount = COUNT(*) FROM sys.sql_modules m
        JOIN sys.objects o ON m.object_id = o.object_id
        WHERE o.type IN (''P'',''V'',''TF'',''IF'',''FN'',''TR'')
        AND m.definition IS NOT NULL
        AND (
            m.definition LIKE ''%BULK INSERT%''
            OR m.definition LIKE ''%OPENROWSET(BULK%''
            OR m.definition LIKE ''%TABLOCK%''
            OR m.definition LIKE ''%MINIMAL LOGGING%''
        );
        
        IF @MatchCount > 0
            SET @DbScore = CASE WHEN @MatchCount <= 5 THEN 1 ELSE 2 END;
            
        INSERT INTO #DbResults VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore);';
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
-- NOTE: 'bcp' is a command-line utility and not captured in T-SQL modules; this check focuses on T-SQL bulk patterns.