-- Checklist: No SELECT * in production code; explicit column lists
-- Scope: DATABASE
-- Scoring: 3=0 occurrences, 2=1-3 occurrences, 1=4-10 occurrences, 0=>10 occurrences
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
        DECLARE @Count INT = 0;
        SELECT @Count = COUNT(*) FROM sys.sql_modules m
        JOIN sys.objects o ON m.object_id = o.object_id
        WHERE o.type IN (''P'',''V'',''TF'',''IF'',''TR'',''FN'')
        AND o.is_ms_shipped = 0
        AND (m.definition LIKE ''%SELECT *%'' OR m.definition LIKE ''%SELECT  *%'');
        INSERT INTO #DbResults VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', CASE WHEN @Count = 0 THEN 3 WHEN @Count <= 3 THEN 2 WHEN @Count <= 10 THEN 1 ELSE 0 END);';
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