-- Checklist: Categorical / Enum: values within expected domain; no invalid codes
-- Scope: DATABASE
-- Scoring: 0=No candidates or <10% validated; 1=10-<30% validated; 2=30-<100% validated; 3=100% validated (capped at 2 due to proxy evidence). NOTE: Uses proxy evidence (CHECK/FK constraints). Full compliance requires human review.
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
        DECLARE @TotalCategorical INT = 0;
        DECLARE @ValidatedCategorical INT = 0;
        DECLARE @Pct FLOAT = 0;
        DECLARE @DbScore INT = 0;

        SELECT @TotalCategorical = COUNT(*)
        FROM sys.columns c
        JOIN sys.tables t ON c.object_id = t.object_id
        JOIN sys.types tp ON c.user_type_id = tp.user_type_id
        WHERE t.is_ms_shipped = 0
          AND t.type = ''U''
          AND c.is_computed = 0
          AND tp.name IN (''tinyint'', ''smallint'', ''varchar'', ''nvarchar'', ''char'', ''nchar'')
          AND c.max_length <= 50;

        SELECT @ValidatedCategorical = COUNT(*)
        FROM sys.columns c
        JOIN sys.tables t ON c.object_id = t.object_id
        JOIN sys.types tp ON c.user_type_id = tp.user_type_id
        WHERE t.is_ms_shipped = 0
          AND t.type = ''U''
          AND c.is_computed = 0
          AND tp.name IN (''tinyint'', ''smallint'', ''varchar'', ''nvarchar'', ''char'', ''nchar'')
          AND c.max_length <= 50
          AND (
            EXISTS (SELECT 1 FROM sys.check_constraints cc WHERE cc.parent_object_id = c.object_id AND cc.parent_column_id = c.column_id)
            OR EXISTS (SELECT 1 FROM sys.foreign_keys fk WHERE fk.parent_object_id = c.object_id AND fk.parent_column_id = c.column_id)
          );

        IF @TotalCategorical > 0
            SET @Pct = CAST(@ValidatedCategorical AS FLOAT) / @TotalCategorical * 100;

        SET @DbScore = CASE
            WHEN @TotalCategorical = 0 THEN 0
            WHEN @Pct < 10 THEN 0
            WHEN @Pct < 30 THEN 1
            WHEN @Pct < 100 THEN 2
            ELSE 2
        END;

        INSERT INTO #DbResults VALUES ('' + REPLACE(@DbName, '''', '''''') + ''', @DbScore);
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