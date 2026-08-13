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
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N'; ' +
                   N'DECLARE @FgCount INT = (SELECT COUNT(*) FROM sys.filegroups WHERE name <> ''PRIMARY''); ' +
                   N'DECLARE @TableCount INT = (SELECT COUNT(*) FROM sys.tables t ' +
                   N'JOIN sys.indexes i ON t.object_id = i.object_id AND i.index_id <= 1 ' +
                   N'JOIN sys.filegroups fg ON i.data_space_id = fg.data_space_id ' +
                   N'WHERE fg.name <> ''PRIMARY''); ' +
                   N'DECLARE @DbScore INT = 0; ' +
                   N'IF @FgCount = 0 SET @DbScore = 0; ' +
                   N'ELSE IF @TableCount = 0 SET @DbScore = 1; ' +
                   N'ELSE IF @TableCount < 5 SET @DbScore = 2; ' +
                   N'ELSE SET @DbScore = 3; ' +
                   N'INSERT INTO #DbResults VALUES (@DbName, @DbScore);';
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