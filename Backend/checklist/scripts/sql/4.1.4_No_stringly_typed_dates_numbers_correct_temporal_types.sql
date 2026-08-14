-- Checklist: No stringly-typed dates/numbers; correct temporal types
-- Scope: DATABASE
-- Scoring: 0 = >20 string columns used for dates/numbers; 1 = 10-20; 2 = 1-9; 3 = 0 (fully compliant)
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @OffendingCount INT;

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @OffendingCount = 0;
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        SELECT @Cnt = COUNT(*)
        FROM sys.columns c
        JOIN sys.types t ON c.user_type_id = t.user_type_id
        JOIN sys.tables tab ON c.object_id = tab.object_id
        WHERE t.name IN (''varchar'', ''nvarchar'', ''char'', ''nchar'', ''text'', ''ntext'')
        AND c.is_computed = 0
        AND tab.type = ''U''
        AND (
            LOWER(c.name) LIKE ''%date%'' OR LOWER(c.name) LIKE ''%time%'' OR LOWER(c.name) LIKE ''%dt%'' OR LOWER(c.name) LIKE ''%ts%''
            OR LOWER(c.name) LIKE ''%num%'' OR LOWER(c.name) LIKE ''%amount%'' OR LOWER(c.name) LIKE ''%price%'' OR LOWER(c.name) LIKE ''%qty%'' OR LOWER(c.name) LIKE ''%count%'' OR LOWER(c.name) LIKE ''%total%''
        );';
        
        EXEC sp_executesql @Sql, N'@Cnt INT OUTPUT', @Cnt = @OffendingCount OUTPUT;
    END TRY
    BEGIN CATCH
        SET @OffendingCount = 999;
    END CATCH;

    SET @Score = CASE 
        WHEN @OffendingCount = 0 THEN 3
        WHEN @OffendingCount BETWEEN 1 AND 9 THEN 2
        WHEN @OffendingCount BETWEEN 10 AND 20 THEN 1
        ELSE 0
    END;

    INSERT INTO #DbResults VALUES (@DbName, @Score);
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;