-- Checklist: ETL has structured error handling (TRY...CATCH, event handlers, failure paths)
-- Scope: DATABASE
-- Scoring: 0 = 0% coverage, 1 = 1-24%, 2 = 25-74%, 3 = 75-100% of modules contain TRY/CATCH. NOTE: This script provides automated evidence. Full compliance requires human review.
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
        DECLARE @Total INT = (SELECT COUNT(*) FROM sys.objects WHERE type IN (''P'',''PC'',''FN'',''IF'',''TF'',''TR''));
        DECLARE @WithTryCatch INT = (SELECT COUNT(*) FROM sys.objects o JOIN sys.sql_modules m ON o.object_id = m.object_id WHERE type IN (''P'',''PC'',''FN'',''IF'',''TF'',''TR'') AND m.definition LIKE ''%TRY%'' AND m.definition LIKE ''%CATCH%'');
        DECLARE @Pct FLOAT = CASE WHEN @Total > 0 THEN (@WithTryCatch * 100.0 / @Total) ELSE 100.0 END;
        DECLARE @DbScore INT = CASE 
            WHEN @Pct >= 75 THEN 3
            WHEN @Pct >= 25 THEN 2
            WHEN @Pct > 0 THEN 1
            ELSE 0
        END;
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