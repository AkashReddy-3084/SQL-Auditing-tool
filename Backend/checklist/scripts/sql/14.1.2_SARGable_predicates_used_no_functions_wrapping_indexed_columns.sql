-- Checklist: SARGable predicates used (no functions wrapping indexed columns)
-- Scope: DATABASE
-- Scoring: 0 = >10 non-SARGable patterns found, 1 = 4-10 patterns, 2 = 1-3 patterns, 3 = 0 patterns found.
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
DECLARE @ViolationCount INT = 0;
SELECT @ViolationCount = COUNT(*)
FROM sys.sql_modules m
JOIN sys.objects o ON m.object_id = o.object_id
WHERE o.type IN (''P'',''V'',''TF'',''IF'',''TR'')
  AND m.definition IS NOT NULL
  AND (
    m.definition LIKE ''%WHERE YEAR(%''
    OR m.definition LIKE ''%WHERE MONTH(%''
    OR m.definition LIKE ''%WHERE DAY(%''
    OR m.definition LIKE ''%WHERE LEFT(%''
    OR m.definition LIKE ''%WHERE RIGHT(%''
    OR m.definition LIKE ''%WHERE ISNULL(%''
    OR m.definition LIKE ''%WHERE COALESCE(%''
    OR m.definition LIKE ''%WHERE UPPER(%''
    OR m.definition LIKE ''%WHERE LOWER(%''
    OR m.definition LIKE ''%WHERE CONVERT(%''
    OR m.definition LIKE ''%WHERE CAST(%''
  );

INSERT INTO #DbResults
SELECT ''' + @DbName + ''',
       CASE
         WHEN @ViolationCount = 0 THEN 3
         WHEN @ViolationCount <= 3 THEN 2
         WHEN @ViolationCount <= 10 THEN 1
         ELSE 0
       END;
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