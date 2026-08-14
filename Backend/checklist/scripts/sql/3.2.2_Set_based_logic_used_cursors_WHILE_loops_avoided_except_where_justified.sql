-- Checklist: Set-based logic used; cursors/WHILE loops avoided except where justified
-- Scope: DATABASE
-- Scoring: 3=0% objects use cursors/WHILE, 2=1-5%, 1=6-20%, 0=>20%
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @Total INT = 0;
        DECLARE @Flagged INT = 0;
        SELECT @Total = COUNT(*) FROM sys.sql_modules m JOIN sys.objects o ON m.object_id = o.object_id WHERE o.type IN (''P'',''IF'',''TF'',''FN'',''TR'');
        SELECT @Flagged = COUNT(*) FROM sys.sql_modules m JOIN sys.objects o ON m.object_id = o.object_id WHERE o.type IN (''P'',''IF'',''TF'',''FN'',''TR'') AND (m.definition LIKE ''%CURSOR%'' OR m.definition LIKE ''%WHILE%'');
        INSERT INTO #DbResults VALUES (''' + @DbName + ''', CASE 
            WHEN @Total = 0 THEN 3 
            WHEN @Flagged = 0 THEN 3 
            WHEN CAST(@Flagged AS FLOAT) / @Total <= 0.05 THEN 2 
            WHEN CAST(@Flagged AS FLOAT) / @Total <= 0.20 THEN 1 
            ELSE 0 
        END);';
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