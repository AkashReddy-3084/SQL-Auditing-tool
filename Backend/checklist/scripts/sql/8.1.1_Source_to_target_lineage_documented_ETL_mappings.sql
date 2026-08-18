-- Checklist: Source-to-target lineage documented (ETL mappings)
-- Scope: DATABASE
-- Scoring: 3 if >=80% of user tables have lineage/mapping extended properties; 2 if 20-79%; 1 if 1-19%; 0 if 0%.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;
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

IF @IsAzureSQLDB = 1
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
        DECLARE @TotalTables INT;
        DECLARE @LineageTables INT;
        DECLARE @Pct DECIMAL(5,2);
        DECLARE @DbScore INT;
        DECLARE @DbFinding NVARCHAR(MAX);

        SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE type = ''U'';
        SELECT @LineageTables = COUNT(DISTINCT object_id) FROM sys.extended_properties
        WHERE class = 1 AND (value LIKE ''%lineage%'' OR value LIKE ''%mapping%'' OR value LIKE ''%source%'' OR value LIKE ''%etl%'' OR value LIKE ''%origin%'');

        SET @Pct = CASE WHEN @TotalTables = 0 THEN 100 ELSE (@LineageTables * 100.0 / @TotalTables) END;

        SET @DbScore = CASE
            WHEN @Pct >= 80 THEN 3
            WHEN @Pct >= 20 THEN 2
            WHEN @Pct >= 1 THEN 1
            ELSE 0
        END;

        SET @DbFinding = ''Coverage: '' + CAST(@Pct AS NVARCHAR(10)) + ''% ('' + CAST(@LineageTables AS NVARCHAR(10)) + ''/' + CAST(@TotalTables AS NVARCHAR(10)) + '' tables)'';

        SELECT ''' + @DbName + ''' AS DbName, @DbScore AS DbScore, @DbFinding AS Finding;
    ';
    INSERT INTO #DbResults EXEC sp_executesql @Sql;
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
                DECLARE @TotalTables INT;
                DECLARE @LineageTables INT;
                DECLARE @Pct DECIMAL(5,2);
                DECLARE @DbScore INT;
                DECLARE @DbFinding NVARCHAR(MAX);

                SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE type = ''U'';
                SELECT @LineageTables = COUNT(DISTINCT object_id) FROM sys.extended_properties
                WHERE class = 1 AND (value LIKE ''%lineage%'' OR value LIKE ''%mapping%'' OR value LIKE ''%source%'' OR value LIKE ''%etl%'' OR value LIKE ''%origin%'');

                SET @Pct = CASE WHEN @TotalTables = 0 THEN 100 ELSE (@LineageTables * 100.0 / @TotalTables) END;

                SET @DbScore = CASE
                    WHEN @Pct >= 80 THEN 3
                    WHEN @Pct >= 20 THEN 2
                    WHEN @Pct >= 1 THEN 1
                    ELSE 0
                END;

                SET @DbFinding = ''Coverage: '' + CAST(@Pct AS NVARCHAR(10)) + ''% ('' + CAST(@LineageTables AS NVARCHAR(10)) + ''/' + CAST(@TotalTables AS NVARCHAR(10)) + '' tables)'';

                SELECT ''' + @DbName + ''' AS DbName, @DbScore AS DbScore, @DbFinding AS Finding;
            ';
            INSERT INTO #DbResults EXEC sp_executesql @Sql;
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