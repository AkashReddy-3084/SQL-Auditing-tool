DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

-- Create temp table to collect per-database results
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
        DECLARE @TotalTables INT, @DocTables INT, @TotalCols INT, @DocCols INT;
        DECLARE @TablePct FLOAT, @ColPct FLOAT;
        DECLARE @DbScore INT;

        -- Count User Tables
        SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE type = ''U'';
        SELECT @DocTables = COUNT(*) FROM sys.tables t
        JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.minor_id = 0
        WHERE t.type = ''U'' AND ep.name = ''MS_Description'';

        -- Count Table Columns Only
        SELECT @TotalCols = COUNT(*) FROM sys.columns c
        JOIN sys.tables t ON c.object_id = t.object_id WHERE t.type = ''U'';
        SELECT @DocCols = COUNT(*) FROM sys.columns c
        JOIN sys.tables t ON c.object_id = t.object_id
        JOIN sys.extended_properties ep ON c.object_id = ep.major_id AND c.column_id = ep.minor_id
        WHERE t.type = ''U'' AND ep.name = ''MS_Description'';

        -- Calculate percentages (handle division by zero)
        SET @TablePct = CASE WHEN @TotalTables > 0 THEN CAST(@DocTables AS FLOAT) / @TotalTables * 100 ELSE 100 END;
        SET @ColPct = CASE WHEN @TotalCols > 0 THEN CAST(@DocCols AS FLOAT) / @TotalCols * 100 ELSE 100 END;

        -- Determine Score based on coverage
        IF @TablePct > 75 AND @ColPct > 75 SET @DbScore = 3;
        ELSE IF @TablePct > 25 AND @ColPct > 25 SET @DbScore = 2;
        ELSE IF @DocTables > 0 OR @DocCols > 0 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

        INSERT INTO #DbResults VALUES (@DbNameParam, @DbScore);';

        EXEC sp_executesql @Sql, N'@DbNameParam NVARCHAR(256)', @DbNameParam = @DbName;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Aggregate: worst-case score across all databases
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;