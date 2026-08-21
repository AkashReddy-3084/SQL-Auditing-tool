-- Checklist: Metadata accessible to consumers (discoverable)
-- Scope: DATABASE
-- Scoring: 3: >=80% of tables/columns have descriptions; 2: >=40% have descriptions; 1: >0% have descriptions; 0: 0% have descriptions.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @TotalTables INT, @DescTables INT, @TotalCols INT, @DescCols INT;
    SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0;
    SELECT @DescTables = COUNT(*) FROM sys.tables t
    JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.minor_id = 0 AND ep.name = ''MS_Description''
    WHERE t.is_ms_shipped = 0;
    SELECT @TotalCols = COUNT(*) FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE t.is_ms_shipped = 0;
    SELECT @DescCols = COUNT(*) FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id
    JOIN sys.extended_properties ep ON c.object_id = ep.major_id AND c.column_id = ep.minor_id AND ep.name = ''MS_Description''
    WHERE t.is_ms_shipped = 0;

    DECLARE @TablePct FLOAT = CASE WHEN @TotalTables > 0 THEN CAST(@DescTables AS FLOAT) / @TotalTables * 100 ELSE 0 END;
    DECLARE @ColPct FLOAT = CASE WHEN @TotalCols > 0 THEN CAST(@DescCols AS FLOAT) / @TotalCols * 100 ELSE 0 END;
    DECLARE @AvgPct FLOAT = (@TablePct + @ColPct) / 2.0;

    DECLARE @DbScore INT = CASE
        WHEN @AvgPct >= 80 THEN 3
        WHEN @AvgPct >= 40 THEN 2
        WHEN @AvgPct > 0 THEN 1
        ELSE 0
    END;

    DECLARE @DbFinding NVARCHAR(MAX) = ''Table coverage: '' + CAST(@TablePct AS NVARCHAR(10)) + ''% ('' + CAST(@DescTables AS NVARCHAR(10)) + ''/' + CAST(@TotalTables AS NVARCHAR(10)) + ''); Column coverage: '' + CAST(@ColPct AS NVARCHAR(10)) + ''% ('' + CAST(@DescCols AS NVARCHAR(10)) + ''/' + CAST(@TotalCols AS NVARCHAR(10)) + '')'';

    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + @DbName + ''', @DbScore, @DbFinding);';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4
      AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @TotalTables INT, @DescTables INT, @TotalCols INT, @DescCols INT;
            SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0;
            SELECT @DescTables = COUNT(*) FROM sys.tables t
            JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.minor_id = 0 AND ep.name = ''MS_Description''
            WHERE t.is_ms_shipped = 0;
            SELECT @TotalCols = COUNT(*) FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE t.is_ms_shipped = 0;
            SELECT @DescCols = COUNT(*) FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id
            JOIN sys.extended_properties ep ON c.object_id = ep.major_id AND c.column_id = ep.minor_id AND ep.name = ''MS_Description''
            WHERE t.is_ms_shipped = 0;

            DECLARE @TablePct FLOAT = CASE WHEN @TotalTables > 0 THEN CAST(@DescTables AS FLOAT) / @TotalTables * 100 ELSE 0 END;
            DECLARE @ColPct FLOAT = CASE WHEN @TotalCols > 0 THEN CAST(@DescCols AS FLOAT) / @TotalCols * 100 ELSE 0 END;
            DECLARE @AvgPct FLOAT = (@TablePct + @ColPct) / 2.0;

            DECLARE @DbScore INT = CASE
                WHEN @AvgPct >= 80 THEN 3
                WHEN @AvgPct >= 40 THEN 2
                WHEN @AvgPct > 0 THEN 1
                ELSE 0
            END;

            DECLARE @DbFinding NVARCHAR(MAX) = ''Table coverage: '' + CAST(@TablePct AS NVARCHAR(10)) + ''% ('' + CAST(@DescTables AS NVARCHAR(10)) + ''/' + CAST(@TotalTables AS NVARCHAR(10)) + ''); Column coverage: '' + CAST(@ColPct AS NVARCHAR(10)) + ''% ('' + CAST(@DescCols AS NVARCHAR(10)) + ''/' + CAST(@TotalCols AS NVARCHAR(10)) + '')'';

            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + @DbName + ''', @DbScore, @DbFinding);';
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Database evaluation failed');
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = (
    SELECT STRING_AGG(DbName, ', ')
    FROM #DbResults
);

SET @Score = ISNULL(
    (SELECT MIN(DbScore) FROM #DbResults),
    0
);

SET @Finding = ISNULL(
    (
        SELECT STRING_AGG(DbName + ': ' + Finding, '; ')
        FROM #DbResults
        WHERE Finding IS NOT NULL
          AND Finding <> ''
    ),
    'No non-compliant findings found'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;