-- Checklist: Transformation logic documented and reproducible
-- Scope: DATABASE
-- Scoring: 0=0% documented, 1=1-49%, 2=50-89%, 3=90-100% of transformation objects have comments or extended properties
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
        DECLARE @Documented INT = 0;

        SELECT @Total = COUNT(*) FROM sys.objects WHERE type IN (''P'',''V'',''FN'',''IF'',''TF'') AND is_ms_shipped = 0;

        SELECT @Documented = COUNT(*) FROM sys.objects o
        WHERE type IN (''P'',''V'',''FN'',''IF'',''TF'') AND is_ms_shipped = 0
        AND (
            EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE ep.major_id = o.object_id AND ep.name = ''MS_Description'')
            OR EXISTS (SELECT 1 FROM sys.sql_modules sm WHERE sm.object_id = o.object_id AND (sm.definition LIKE ''%--%'' OR sm.definition LIKE ''%/*%''))
        );

        INSERT INTO #DbResults VALUES (''' + @DbName + ''', CASE
            WHEN @Total = 0 THEN 3
            WHEN CAST(@Documented AS FLOAT) / @Total >= 0.9 THEN 3
            WHEN CAST(@Documented AS FLOAT) / @Total >= 0.5 THEN 2
            WHEN @Documented > 0 THEN 1
            ELSE 0
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

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;