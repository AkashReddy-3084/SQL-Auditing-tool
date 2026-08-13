-- Checklist: Code is commented for complex logic; business rules explained
-- Scope: DATABASE
-- Scoring: 0 = No comments found; 1 = <25% of objects commented; 2 = 25-99% commented; 3 = 100% commented (capped at 2 due to proxy evidence requiring human review)
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
        DECLARE @Commented INT = 0;
        SELECT @Total = COUNT(*) FROM sys.objects WHERE type IN (''P'',''FN'',''IF'',''TF'',''TR'',''V'') AND is_ms_shipped = 0;
        SELECT @Commented = COUNT(*) FROM sys.objects o
        WHERE type IN (''P'',''FN'',''IF'',''TF'',''TR'',''V'') AND is_ms_shipped = 0
        AND (
            EXISTS (SELECT 1 FROM sys.sql_modules m WHERE m.object_id = o.object_id AND (m.definition LIKE ''%--%'' OR m.definition LIKE ''%/*%''))
            OR EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE ep.major_id = o.object_id AND ep.minor_id = 0 AND ep.class = 1)
        );
        INSERT INTO #DbResults VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', CASE
            WHEN @Total = 0 THEN 0
            WHEN @Commented = 0 THEN 0
            WHEN CAST(@Commented AS FLOAT) / @Total < 0.25 THEN 1
            ELSE 2
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