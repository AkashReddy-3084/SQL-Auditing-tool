-- Checklist: Extended properties / documentation on key objects
-- Scope: DATABASE
-- Scoring: 0 = 0% documented, 1 = 1-24% documented, 2 = 25-74% documented, 3 = >= 75% documented
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
        DECLARE @TotalItems INT;
        DECLARE @DocItems INT;
        DECLARE @Pct FLOAT;
        DECLARE @DbScore INT = 0;

        ;WITH AllItems AS (
            SELECT o.object_id AS major_id, 0 AS minor_id
            FROM sys.objects o
            JOIN sys.schemas s ON o.schema_id = s.schema_id
            WHERE o.type IN ('U', 'V', 'P', 'FN', 'IF', 'TF') AND s.name NOT IN ('sys', 'INFORMATION_SCHEMA')
            UNION ALL
            SELECT c.object_id, c.column_id
            FROM sys.columns c
            JOIN sys.objects o ON c.object_id = o.object_id
            JOIN sys.schemas s ON o.schema_id = s.schema_id
            WHERE o.type IN ('U', 'V') AND s.name NOT IN ('sys', 'INFORMATION_SCHEMA')
        )
        SELECT @TotalItems = COUNT(*),
               @DocItems = SUM(CASE WHEN EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE ep.major_id = AllItems.major_id AND ep.minor_id = AllItems.minor_id) THEN 1 ELSE 0 END)
        FROM AllItems;

        SET @Pct = CAST(@DocItems AS FLOAT) / NULLIF(@TotalItems, 0) * 100;

        IF @TotalItems = 0 SET @DbScore = 0;
        ELSE IF @Pct >= 75 SET @DbScore = 3;
        ELSE IF @Pct >= 25 SET @DbScore = 2;
        ELSE IF @Pct > 0 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

        INSERT INTO #DbResults VALUES (@DbName, @DbScore);
        ';
        EXEC sp_executesql @Sql, N'@DbName NVARCHAR(256)', @DbName = @DbName;
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