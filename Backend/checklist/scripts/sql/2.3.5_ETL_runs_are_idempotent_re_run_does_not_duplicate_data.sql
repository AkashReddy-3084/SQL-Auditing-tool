SET NOCOUNT ON;
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
        DECLARE @TotalDML INT = 0;
        DECLARE @Idempotent INT = 0;

        SELECT @TotalDML = COUNT(*)
        FROM sys.procedures p
        JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE p.is_ms_shipped = 0
        AND (m.definition LIKE ''%INSERT%'' OR m.definition LIKE ''%UPDATE%'' OR m.definition LIKE ''%MERGE%'');

        SELECT @Idempotent = COUNT(*)
        FROM sys.procedures p
        JOIN sys.sql_modules m ON p.object_id = m.object_id
        WHERE p.is_ms_shipped = 0
        AND (m.definition LIKE ''%INSERT%'' OR m.definition LIKE ''%UPDATE%'' OR m.definition LIKE ''%MERGE%'')
        AND (m.definition LIKE ''%MERGE%'' OR m.definition LIKE ''%DELETE FROM%'' OR m.definition LIKE ''%WHERE NOT EXISTS%'' OR m.definition LIKE ''%IF NOT EXISTS%'' OR m.definition LIKE ''%TRUNCATE TABLE%'');

        DECLARE @DbScore INT = 0;
        IF @TotalDML = 0 SET @DbScore = 0;
        ELSE BEGIN
            DECLARE @Pct FLOAT = CAST(@Idempotent AS FLOAT) / CAST(@TotalDML AS FLOAT);
            IF @Pct >= 0.5 SET @DbScore = 2;
            ELSE IF @Pct > 0.0 SET @DbScore = 1;
            ELSE SET @DbScore = 0;
        END;

        INSERT INTO #DbResults VALUES (@DbParam, @DbScore);
        ';
        EXEC sp_executesql @Sql, N'@DbParam NVARCHAR(256)', @DbParam = @DbName;
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