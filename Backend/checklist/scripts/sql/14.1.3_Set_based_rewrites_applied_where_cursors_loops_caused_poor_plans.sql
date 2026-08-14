-- Checklist: Set-based rewrites applied where cursors/loops caused poor plans
-- Scope: DATABASE
-- Scoring: 3=Zero cursor/loop objects found; 2=1-5 objects (proxy evidence, requires review); 1=6-15 objects; 0=>15 objects.
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
        DECLARE @Count INT = 0;
        SELECT @Count = COUNT(DISTINCT o.object_id)
        FROM sys.sql_modules m
        JOIN sys.objects o ON m.object_id = o.object_id
        WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'')
        AND (
            m.definition LIKE ''%CURSOR%''
            OR m.definition LIKE ''%WHILE%''
            OR m.definition LIKE ''%FETCH NEXT%''
        );

        INSERT INTO #DbResults (DbName, DbScore)
        VALUES (''' + @DbName + ''',
            CASE
                WHEN @Count = 0 THEN 3
                WHEN @Count BETWEEN 1 AND 5 THEN 2
                WHEN @Count BETWEEN 6 AND 15 THEN 1
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