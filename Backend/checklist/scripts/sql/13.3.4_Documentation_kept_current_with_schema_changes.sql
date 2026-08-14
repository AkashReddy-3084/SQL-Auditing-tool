DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Params NVARCHAR(500);

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
            DECLARE @Total INT = (SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0) + (SELECT COUNT(*) FROM sys.columns c INNER JOIN sys.tables t ON c.object_id = t.object_id WHERE t.is_ms_shipped = 0);
            DECLARE @Doc INT = (SELECT COUNT(*) FROM sys.extended_properties ep INNER JOIN sys.tables t ON ep.major_id = t.object_id WHERE ep.name = ''MS_Description'' AND ep.minor_id = 0 AND t.is_ms_shipped = 0) + (SELECT COUNT(*) FROM sys.extended_properties ep INNER JOIN sys.columns c ON ep.major_id = c.object_id AND ep.minor_id = c.column_id INNER JOIN sys.tables t ON c.object_id = t.object_id WHERE ep.name = ''MS_Description'' AND t.is_ms_shipped = 0);
            DECLARE @Cov DECIMAL(5,2) = CASE WHEN @Total = 0 THEN 100 ELSE (@Doc * 100.0) / @Total END;
            DECLARE @S INT = CASE WHEN @Cov >= 90 THEN 3 WHEN @Cov >= 50 THEN 2 WHEN @Cov >= 20 THEN 1 ELSE 0 END;
            INSERT INTO #DbResults VALUES (@DbNameParam, @S);';
        SET @Params = N'@DbNameParam NVARCHAR(256)';
        EXEC sp_executesql @Sql, @Params, @DbNameParam = @DbName;
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