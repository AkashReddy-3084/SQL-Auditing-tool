-- Checklist: Audit metadata captured on load (load_date, source_system, batch_id)
-- Scope: DATABASE
-- Scoring: 0 = <25% of relevant tables contain audit columns; 1 = 25-74% contain them; 2 = 75-99% contain them; 3 = 100% contain them
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
        DECLARE @TotalTables INT = 0;
        DECLARE @CompliantTables INT = 0;

        SELECT @TotalTables = COUNT(*)
        FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE t.is_ms_shipped = 0
        AND (
            s.name IN (''staging'', ''ods'', ''dw'', ''mart'', ''data_warehouse'', ''data_mart'')
            OR t.name LIKE ''%staging%'' OR t.name LIKE ''%ods%'' OR t.name LIKE ''%dw%'' OR t.name LIKE ''%mart%''
        );

        IF @TotalTables > 0
        BEGIN
            SELECT @CompliantTables = COUNT(*)
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE t.is_ms_shipped = 0
            AND (
                s.name IN (''staging'', ''ods'', ''dw'', ''mart'', ''data_warehouse'', ''data_mart'')
                OR t.name LIKE ''%staging%'' OR t.name LIKE ''%ods%'' OR t.name LIKE ''%dw%'' OR t.name LIKE ''%mart%''
            )
            AND EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = t.object_id AND c.name = ''load_date'')
            AND EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = t.object_id AND c.name = ''source_system'')
            AND EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = t.object_id AND c.name = ''batch_id'');

            DECLARE @Pct FLOAT = CAST(@CompliantTables AS FLOAT) / @TotalTables * 100;
            DECLARE @DbScore INT = CASE
                WHEN @Pct = 100 THEN 3
                WHEN @Pct >= 75 THEN 2
                WHEN @Pct >= 25 THEN 1
                ELSE 0
            END;
            INSERT INTO #DbResults VALUES (@DbName, @DbScore);
        END
        ELSE
        BEGIN
            INSERT INTO #DbResults VALUES (@DbName, 0);
        END
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