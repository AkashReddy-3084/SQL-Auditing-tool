-- Checklist: Code is self-documenting or well-commented for complex logic
-- Scope: DATABASE
-- Scoring: 0 = 0% modules contain comments/extended properties, 1 = 1-24%, 2 = 25-74%, 3 = 75-100% (capped at 2 due to proxy evidence)
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
        DECLARE @Commented INT = 0;
        
        SELECT @Total = COUNT(*) FROM sys.objects WHERE type IN (''P'',''FN'',''TF'',''IF'',''TR'',''V'');
        
        SELECT @Commented = COUNT(*) FROM sys.objects o
        JOIN sys.sql_modules m ON o.object_id = m.object_id
        WHERE type IN (''P'',''FN'',''TF'',''IF'',''TR'',''V'')
        AND (m.definition LIKE ''%--%'' OR m.definition LIKE ''%/*%'' OR EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE ep.major_id = o.object_id AND ep.minor_id = 0));
        
        DECLARE @Pct INT = CASE WHEN @Total = 0 THEN 100 ELSE (@Commented * 100) / @Total END;
        
        DECLARE @DbScore INT = CASE 
            WHEN @Pct = 0 THEN 0
            WHEN @Pct BETWEEN 1 AND 24 THEN 1
            WHEN @Pct >= 25 THEN 2
            ELSE 3
        END;
        
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

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;