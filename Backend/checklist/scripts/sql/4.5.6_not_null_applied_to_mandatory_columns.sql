DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DbScore INT;

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
        DECLARE @NullableCount INT;
        DECLARE @TotalCount INT;
        SELECT @NullableCount = SUM(CASE WHEN is_nullable = 1 THEN 1 ELSE 0 END),
               @TotalCount = COUNT(*)
        FROM sys.columns c
        JOIN sys.tables t ON c.object_id = t.object_id;

        IF @TotalCount = 0
            SET @DbScore = 3;
        ELSE
        BEGIN
            DECLARE @Pct FLOAT = CAST(@NullableCount AS FLOAT) / @TotalCount;
            SET @DbScore = CASE
                WHEN @NullableCount = 0 THEN 3
                WHEN @Pct <= 0.20 THEN 2
                WHEN @Pct <= 0.50 THEN 1
                ELSE 0
            END;
        END;
        ';
        EXEC sp_executesql @Sql, N'@DbScore INT OUTPUT', @DbScore OUTPUT;
        INSERT INTO #DbResults VALUES (@DbName, @DbScore);
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score = 3 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;