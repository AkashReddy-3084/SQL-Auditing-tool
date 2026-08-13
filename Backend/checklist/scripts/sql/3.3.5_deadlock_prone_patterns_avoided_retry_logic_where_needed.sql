-- Checklist: Deadlock-prone patterns avoided; retry logic where needed
-- Scope: DATABASE
-- Scoring: 0 = <20% coverage, 1 = 20-49%, 2 = 50-79%, 3 = >=80% of relevant procedures contain retry/deadlock mitigation logic.
-- NOTE: This script provides automated evidence. Full compliance requires human review.
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
        DECLARE @TotalRelevant INT = 0;
        DECLARE @WithRetry INT = 0;
        
        SELECT @TotalRelevant = COUNT(*) FROM sys.procedures p
        JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE m.definition LIKE CHAR(37) + ''BEGIN TRAN'' + CHAR(37) 
           OR m.definition LIKE CHAR(37) + ''UPDATE '' + CHAR(37) 
           OR m.definition LIKE CHAR(37) + ''INSERT '' + CHAR(37) 
           OR m.definition LIKE CHAR(37) + ''DELETE '' + CHAR(37);
        
        SELECT @WithRetry = COUNT(*) FROM sys.procedures p
        JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE (m.definition LIKE CHAR(37) + ''TRY'' + CHAR(37) AND m.definition LIKE CHAR(37) + ''CATCH'' + CHAR(37))
          AND (m.definition LIKE CHAR(37) + ''WHILE'' + CHAR(37) OR m.definition LIKE CHAR(37) + ''WAITFOR'' + CHAR(37) OR m.definition LIKE CHAR(37) + ''LOCK_TIMEOUT'' + CHAR(37) OR m.definition LIKE CHAR(37) + ''XACT_ABORT'' + CHAR(37));
          
        DECLARE @Pct FLOAT = CASE WHEN @TotalRelevant > 0 THEN (@WithRetry * 100.0 / @TotalRelevant) ELSE 0 END;
        DECLARE @DbScore INT = 0;
        
        IF @Pct >= 80 SET @DbScore = 3;
        ELSE IF @Pct >= 50 SET @DbScore = 2;
        ELSE IF @Pct >= 20 SET @DbScore = 1;
        ELSE SET @DbScore = 0;
        
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