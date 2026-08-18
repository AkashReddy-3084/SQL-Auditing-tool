-- Checklist: Cross-layer reconciliation (mart vs integration vs source counts)
-- Scope: DATABASE
-- Scoring: 3: >=95% of matched tables have identical row counts across layers. 2: 80-94% match. 1: 50-79% match. 0: <50% match or no cross-layer tables found.
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
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @SourceTables TABLE (TableName NVARCHAR(128), RowCount BIGINT);
    DECLARE @MartTables TABLE (TableName NVARCHAR(128), RowCount BIGINT);
    DECLARE @TotalPairs INT = 0;
    DECLARE @MatchedPairs INT = 0;
    DECLARE @MismatchedTables NVARCHAR(MAX) = '';

    INSERT INTO @SourceTables
    SELECT t.name, SUM(p.row_count)
    FROM sys.tables t
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    JOIN sys.dm_db_partition_stats p ON t.object_id = p.object_id AND p.index_id < 2
    WHERE s.name LIKE ''%stg%'' OR s.name LIKE ''%integration%'' OR s.name LIKE ''%source%'' OR s.name LIKE ''%raw%''
    GROUP BY t.name;

    INSERT INTO @MartTables
    SELECT t.name, SUM(p.row_count)
    FROM sys.tables t
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    JOIN sys.dm_db_partition_stats p ON t.object_id = p.object_id AND p.index_id < 2
    WHERE s.name LIKE ''%mart%'' OR s.name LIKE ''%dwh%'' OR s.name LIKE ''%curated%'' OR s.name LIKE ''%dw%''
    GROUP BY t.name;

    SELECT @TotalPairs = COUNT(*), @MatchedPairs = SUM(CASE WHEN s.RowCount = m.RowCount THEN 1 ELSE 0 END)
    FROM @SourceTables s
    INNER JOIN @MartTables m ON s.TableName = m.TableName;

    SELECT @MismatchedTables = STRING_AGG(s.TableName + '' ('' + CAST(s.RowCount AS NVARCHAR) + '' vs '' + CAST(m.RowCount AS NVARCHAR) + '')'', '', '')
    FROM @SourceTables s
    INNER JOIN @MartTables m ON s.TableName = m.TableName
    WHERE s.RowCount <> m.RowCount;

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        ''' + @DbName + N''',
        CASE 
            WHEN @TotalPairs = 0 THEN 0
            WHEN CAST(@MatchedPairs AS FLOAT) / @TotalPairs >= 0.95 THEN 3
            WHEN CAST(@MatchedPairs AS FLOAT) / @TotalPairs >= 0.80 THEN 2
            WHEN CAST(@MatchedPairs AS FLOAT) / @TotalPairs >= 0.50 THEN 1
            ELSE 0
        END,
        CASE 
            WHEN @TotalPairs = 0 THEN ''No cross-layer tables found for reconciliation''
            WHEN @MismatchedTables IS NULL OR @MismatchedTables = '''' THEN ''All matched tables have identical row counts across layers''
            ELSE ''Discrepancies found: '' + @MismatchedTables
        END
    );
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
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
            DECLARE @SourceTables TABLE (TableName NVARCHAR(128), RowCount BIGINT);
            DECLARE @MartTables TABLE (TableName NVARCHAR(128), RowCount BIGINT);
            DECLARE @TotalPairs INT = 0;
            DECLARE @MatchedPairs INT = 0;
            DECLARE @MismatchedTables NVARCHAR(MAX) = '';

            INSERT INTO @SourceTables
            SELECT t.name, SUM(p.row_count)
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            JOIN sys.dm_db_partition_stats p ON t.object_id = p.object_id AND p.index_id < 2
            WHERE s.name LIKE ''%stg%'' OR s.name LIKE ''%integration%'' OR s.name LIKE ''%source%'' OR s.name LIKE ''%raw%''
            GROUP BY t.name;

            INSERT INTO @MartTables
            SELECT t.name, SUM(p.row_count)
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            JOIN sys.dm_db_partition_stats p ON t.object_id = p.object_id AND p.index_id < 2
            WHERE s.name LIKE ''%mart%'' OR s.name LIKE ''%dwh%'' OR s.name LIKE ''%curated%'' OR s.name LIKE ''%dw%''
            GROUP BY t.name;

            SELECT @TotalPairs = COUNT(*), @MatchedPairs = SUM(CASE WHEN s.RowCount = m.RowCount THEN 1 ELSE 0 END)
            FROM @SourceTables s
            INNER JOIN @MartTables m ON s.TableName = m.TableName;

            SELECT @MismatchedTables = STRING_AGG(s.TableName + '' ('' + CAST(s.RowCount AS NVARCHAR) + '' vs '' + CAST(m.RowCount AS NVARCHAR) + '')'', '', '')
            FROM @SourceTables s
            INNER JOIN @MartTables m ON s.TableName = m.TableName
            WHERE s.RowCount <> m.RowCount;

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (
                ''' + @DbName + N''',
                CASE 
                    WHEN @TotalPairs = 0 THEN 0
                    WHEN CAST(@MatchedPairs AS FLOAT) / @TotalPairs >= 0.95 THEN 3
                    WHEN CAST(@MatchedPairs AS FLOAT) / @TotalPairs >= 0.80 THEN 2
                    WHEN CAST(@MatchedPairs AS FLOAT) / @TotalPairs >= 0.50 THEN 1
                    ELSE 0
                END,
                CASE 
                    WHEN @TotalPairs = 0 THEN ''No cross-layer tables found for reconciliation''
                    WHEN @MismatchedTables IS NULL OR @MismatchedTables = '''' THEN ''All matched tables have identical row counts across layers''
                    ELSE ''Discrepancies found: '' + @MismatchedTables
                END
            );
            ';
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