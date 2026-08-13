-- Checklist: Data types appropriate and right-sized (no oversized varchar, correct numeric precision)
-- Scope: DATABASE
-- Scoring: 0 = >20 oversized columns, 1 = 6-20 oversized, 2 = 1-5 oversized, 3 = 0 oversized (thresholds: varchar/nvarchar >1000 or MAX, decimal/numeric precision >18 or scale >4)
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
        DECLARE @TotalCols INT = 0;
        DECLARE @OversizedCols INT = 0;
        SELECT @TotalCols = COUNT(*)
        FROM sys.columns c
        JOIN sys.types t ON c.user_type_id = t.user_type_id
        JOIN sys.tables tab ON c.object_id = tab.object_id
        WHERE t.name IN (''varchar'', ''nvarchar'', ''decimal'', ''numeric'');

        SELECT @OversizedCols = COUNT(*)
        FROM sys.columns c
        JOIN sys.types t ON c.user_type_id = t.user_type_id
        JOIN sys.tables tab ON c.object_id = tab.object_id
        WHERE (t.name IN (''varchar'', ''nvarchar'') AND (c.max_length = -1 OR c.max_length > 1000))
           OR (t.name IN (''decimal'', ''numeric'') AND (c.precision > 18 OR c.scale > 4));

        DECLARE @DbScore INT = 0;
        IF @TotalCols = 0 SET @DbScore = 3;
        ELSE IF @OversizedCols = 0 SET @DbScore = 3;
        ELSE IF @OversizedCols <= 5 SET @DbScore = 2;
        ELSE IF @OversizedCols <= 20 SET @DbScore = 1;
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