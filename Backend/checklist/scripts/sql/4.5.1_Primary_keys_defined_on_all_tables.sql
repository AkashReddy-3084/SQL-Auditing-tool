-- Checklist: Primary keys defined on all tables
-- Scope: DATABASE
-- Scoring: 0 = 0% of tables have PKs (and tables exist), 1 = 1-49% have PKs, 2 = 50-99% have PKs, 3 = 100% have PKs (or no user tables)
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
        DECLARE @TotalTables INT, @TablesWithPK INT;
        SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0;
        SELECT @TablesWithPK = COUNT(*) FROM sys.tables t
        INNER JOIN sys.indexes i ON t.object_id = i.object_id
        WHERE t.is_ms_shipped = 0 AND i.is_primary_key = 1;

        DECLARE @Missing INT = @TotalTables - @TablesWithPK;
        DECLARE @DbScore INT;
        IF @TotalTables = 0 SET @DbScore = 3;
        ELSE IF @Missing = 0 SET @DbScore = 3;
        ELSE IF CAST(@TablesWithPK AS FLOAT) / @TotalTables >= 0.5 SET @DbScore = 2;
        ELSE IF CAST(@TablesWithPK AS FLOAT) / @TotalTables > 0 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

        INSERT INTO #DbResults VALUES (@pDbName, @DbScore);';
        EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(256)', @pDbName = @DbName;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 3);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;