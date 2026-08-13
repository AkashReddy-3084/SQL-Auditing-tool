DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

IF OBJECT_ID('tempdb..#DbResults') IS NOT NULL DROP TABLE #DbResults;
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
        DECLARE @Total INT = 0;
        DECLARE @Constrained INT = 0;

        SELECT @Total = COUNT(*)
        FROM sys.columns c
        JOIN sys.tables t ON c.object_id = t.object_id
        JOIN sys.types tp ON c.user_type_id = tp.user_type_id
        WHERE tp.name IN (''date'', ''datetime'', ''datetime2'', ''smalldatetime'', ''datetimeoffset'')
          AND t.is_ms_shipped = 0;

        IF @Total > 0
        BEGIN
            SELECT @Constrained = COUNT(*)
            FROM (
                SELECT DISTINCT c.object_id, c.column_id
                FROM sys.columns c
                JOIN sys.tables t ON c.object_id = t.object_id
                JOIN sys.types tp ON c.user_type_id = tp.user_type_id
                LEFT JOIN sys.check_constraints cc ON c.object_id = cc.parent_object_id AND c.column_id = cc.parent_column_id
                LEFT JOIN sys.default_constraints dc ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id
                WHERE tp.name IN (''date'', ''datetime'', ''datetime2'', ''smalldatetime'', ''datetimeoffset'')
                  AND t.is_ms_shipped = 0
                  AND (cc.object_id IS NOT NULL OR dc.object_id IS NOT NULL)
            ) AS constrained_cols;
        END

        DECLARE @Pct FLOAT = CASE WHEN @Total > 0 THEN CAST(@Constrained AS FLOAT) / @Total * 100 ELSE 0 END;
        DECLARE @DbScore INT = CASE
            WHEN @Total = 0 THEN 0
            WHEN @Constrained = 0 THEN 0
            WHEN @Pct < 50 THEN 1
            WHEN @Pct < 100 THEN 2
            ELSE 3
        END;
        INSERT INTO #DbResults VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore);';
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