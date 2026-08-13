-- Checklist: Unused indexes identified and removed (DMV evidence)
-- Scope: DATABASE
-- Scoring: 0 = >10 unused indexes; 1 = 5-10 unused indexes; 2 = 1-4 unused indexes; 3 = 0 unused indexes. NOTE: DMV data resets on service restart, so this provides proxy evidence of cleanup.
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
        DECLARE @UnusedCount INT;
        SELECT @UnusedCount = COUNT(DISTINCT CONVERT(VARCHAR(128), i.object_id) + ''_'' + CONVERT(VARCHAR(128), i.index_id))
        FROM sys.dm_db_index_usage_stats s
        JOIN sys.indexes i ON s.object_id = i.object_id AND s.index_id = i.index_id
        JOIN sys.tables t ON i.object_id = t.object_id
        WHERE s.database_id = DB_ID()
          AND i.type_desc = ''NONCLUSTERED''
          AND s.user_seeks = 0
          AND s.user_scans = 0
          AND s.user_lookups = 0;

        INSERT INTO #DbResults (DbName, DbScore)
        VALUES (''' + @DbName + ''', CASE WHEN @UnusedCount = 0 THEN 3 WHEN @UnusedCount <= 4 THEN 2 WHEN @UnusedCount <= 10 THEN 1 ELSE 0 END);
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