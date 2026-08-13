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
        DECLARE @FactCount INT = 0;
        DECLARE @CompliantCount INT = 0;

        SELECT @FactCount = COUNT(*) FROM sys.tables WHERE UPPER(name) LIKE ''FACT%'';

        IF @FactCount > 0
        BEGIN
            SELECT @CompliantCount = COUNT(*)
            FROM sys.tables t
            WHERE UPPER(t.name) LIKE ''FACT%''
            AND NOT EXISTS (
                SELECT 1 FROM sys.columns c
                JOIN sys.types tp ON c.user_type_id = tp.user_type_id
                WHERE c.object_id = t.object_id
                AND tp.name IN (''varchar'', ''nvarchar'', ''char'', ''nchar'', ''text'', ''ntext'')
                AND NOT EXISTS (
                    SELECT 1 FROM sys.foreign_key_columns fkc
                    WHERE fkc.parent_object_id = t.object_id
                    AND fkc.parent_column_id = c.column_id
                )
            );
        END

        DECLARE @DbScore INT = 0;
        IF @FactCount = 0
            SET @DbScore = 0;
        ELSE
        BEGIN
            DECLARE @Ratio FLOAT = CAST(@CompliantCount AS FLOAT) / @FactCount;
            IF @Ratio = 1.0 SET @DbScore = 3;
            ELSE IF @Ratio >= 0.50 SET @DbScore = 2;
            ELSE IF @Ratio >= 0.25 SET @DbScore = 1;
            ELSE SET @DbScore = 0;
        END

        SELECT ''' + REPLACE(@DbName, '''', '''''') + ''' AS DbName, @DbScore AS DbScore;';
        INSERT INTO #DbResults EXEC(@Sql);
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