-- Checklist: Compression used to reduce storage and IO cost where beneficial
-- Scope: DATABASE
-- Scoring: 0=0% tables compressed, 1=1-24%, 2=25-74%, 3=75-100%
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
        DECLARE @TotalTables INT;
        DECLARE @CompressedTables INT;
        SELECT @TotalTables = COUNT(*) FROM sys.tables;
        SELECT @CompressedTables = COUNT(DISTINCT t.object_id)
        FROM sys.tables t
        INNER JOIN sys.partitions p ON t.object_id = p.object_id
        WHERE p.data_compression > 0;

        DECLARE @Pct FLOAT = CASE WHEN @TotalTables = 0 THEN 100.0 ELSE CAST(@CompressedTables AS FLOAT) / @TotalTables * 100.0 END;
        DECLARE @DbScore INT = CASE 
            WHEN @Pct >= 75 THEN 3
            WHEN @Pct >= 25 THEN 2
            WHEN @Pct >= 1 THEN 1
            ELSE 0
        END;
        INSERT INTO #DbResults VALUES (@DbName, @DbScore);';
        EXEC sp_executesql @Sql, N'@DbName NVARCHAR(256)', @DbName;
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