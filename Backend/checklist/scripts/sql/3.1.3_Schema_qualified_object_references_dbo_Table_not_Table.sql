-- Checklist: Schema-qualified object references (dbo.Table, not Table)
-- Scope: DATABASE
-- Scoring: 0 = >50 objects with unqualified refs, 1 = 10-50 objects, 2 = 1-9 objects, 3 = 0 objects (pattern-matching proxy scan)
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
        DECLARE @UnqualifiedCount INT = 0;
        SELECT @UnqualifiedCount = COUNT(*)
        FROM sys.sql_modules m
        JOIN sys.objects o ON m.object_id = o.object_id
        WHERE o.type IN (''P'',''V'',''TF'',''IF'',''TR'',''FN'')
          AND m.definition IS NOT NULL
          AND (
            (m.definition LIKE ''%FROM [A-Za-z0-9_]%'' AND m.definition NOT LIKE ''%FROM [A-Za-z0-9_].%'')
            OR (m.definition LIKE ''%JOIN [A-Za-z0-9_]%'' AND m.definition NOT LIKE ''%JOIN [A-Za-z0-9_].%'')
            OR (m.definition LIKE ''%UPDATE [A-Za-z0-9_]%'' AND m.definition NOT LIKE ''%UPDATE [A-Za-z0-9_].%'')
            OR (m.definition LIKE ''%INSERT INTO [A-Za-z0-9_]%'' AND m.definition NOT LIKE ''%INSERT INTO [A-Za-z0-9_].%'')
            OR (m.definition LIKE ''%DELETE FROM [A-Za-z0-9_]%'' AND m.definition NOT LIKE ''%DELETE FROM [A-Za-z0-9_].%'')
          );
        INSERT INTO #DbResults VALUES (''' + @DbName + ''', CASE WHEN @UnqualifiedCount = 0 THEN 3 WHEN @UnqualifiedCount <= 9 THEN 2 WHEN @UnqualifiedCount <= 50 THEN 1 ELSE 0 END);
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