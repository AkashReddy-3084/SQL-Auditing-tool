-- Checklist: No duplicate grain in fact tables
-- Scope: DATABASE
-- Scoring: 3 = All fact tables have unique constraint/index. 2 = >80% have unique enforcement. 1 = >0% have unique enforcement. 0 = None have unique enforcement.
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
        DECLARE @TotalFact INT = 0;
        DECLARE @UniqueFact INT = 0;
        SELECT @TotalFact = COUNT(DISTINCT t.object_id)
        FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE t.type = ''U'' AND t.is_ms_shipped = 0 AND (t.name LIKE ''fact%'' OR s.name IN (''fact'', ''dw'', ''mart''));

        SELECT @UniqueFact = COUNT(DISTINCT t.object_id)
        FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id
        JOIN sys.indexes i ON t.object_id = i.object_id
        WHERE t.type = ''U'' AND t.is_ms_shipped = 0 AND (t.name LIKE ''fact%'' OR s.name IN (''fact'', ''dw'', ''mart''))
        AND i.is_unique = 1 AND i.is_disabled = 0 AND i.type IN (1, 2);

        DECLARE @DbScore INT = 0;
        IF @TotalFact = 0 SET @DbScore = 3;
        ELSE IF @UniqueFact = @TotalFact SET @DbScore = 3;
        ELSE IF CAST(@UniqueFact AS FLOAT) / @TotalFact >= 0.8 SET @DbScore = 2;
        ELSE IF @UniqueFact > 0 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

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