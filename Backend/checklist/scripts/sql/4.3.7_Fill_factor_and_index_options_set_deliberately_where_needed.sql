-- Checklist: Fill factor and index options set deliberately where needed
-- Scope: DATABASE
-- Scoring: 0=Fail (<10% deliberate), 1=Partial (10-49%), 2=Mostly (50-89%), 3=Pass (>=90%). Capped at 2 due to "where needed" requiring human judgment.
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
        DECLARE @Total INT = 0;
        DECLARE @Deliberate INT = 0;
        SELECT @Total = COUNT(*), @Deliberate = SUM(CASE WHEN fill_factor > 0 OR is_padded = 1 THEN 1 ELSE 0 END)
        FROM sys.indexes i
        JOIN sys.objects o ON i.object_id = o.object_id
        WHERE o.type IN (''U'', ''V'');

        DECLARE @Pct FLOAT = CASE WHEN @Total = 0 THEN 0 ELSE CAST(@Deliberate AS FLOAT) / @Total * 100 END;
        DECLARE @DbScore INT = CASE 
            WHEN @Pct >= 90 THEN 3 
            WHEN @Pct >= 50 THEN 2 
            WHEN @Pct >= 10 THEN 1 
            ELSE 0 
        END;
        SET @DbScore = CASE WHEN @DbScore = 3 THEN 2 ELSE @DbScore END;
        
        INSERT INTO #DbResults VALUES (' + QUOTENAME(@DbName, '''') + N', @DbScore);';
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