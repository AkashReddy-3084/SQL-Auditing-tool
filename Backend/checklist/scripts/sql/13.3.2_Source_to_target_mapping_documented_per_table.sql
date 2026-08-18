-- Checklist: Source-to-target mapping documented per table
-- Scope: DATABASE
-- Scoring: 0: 0% of tables have mapping documentation. 1: 1-24%. 2: 25-74%. 3: 75-100%.
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
        DECLARE @MappedTables INT;
        DECLARE @Pct DECIMAL(5,2);
        DECLARE @DbScore INT;
        DECLARE @DbFinding NVARCHAR(MAX);

        SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0;

        SELECT @MappedTables = COUNT(DISTINCT t.object_id)
        FROM sys.tables t
        JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.minor_id = 0
        WHERE t.is_ms_shipped = 0
          AND ep.class = 1
          AND (ep.name LIKE ''%[Mm]apping%'' OR ep.name LIKE ''%[Ss]ource%'' OR ep.name LIKE ''%[Ll]ineage%'' OR ep.name LIKE ''%[Ee]tl%'');

        SET @Pct = CASE WHEN @TotalTables = 0 THEN 100.00 ELSE (@MappedTables * 100.0) / @TotalTables END;

        SET @DbScore = CASE
            WHEN @Pct >= 75 THEN 3
            WHEN @Pct >= 25 THEN 2
            WHEN @Pct > 0 THEN 1
            ELSE 0
        END;

        SET @DbFinding = CASE
            WHEN @TotalTables = 0 THEN ''No user tables found.''
            ELSE CAST(@Pct AS NVARCHAR(10)) + ''% of tables have mapping documentation.''
        END;

        INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @TotalTables INT;
            DECLARE @MappedTables INT;
            DECLARE @Pct DECIMAL(5,2);
            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            SELECT @TotalTables = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0;

            SELECT @MappedTables = COUNT(DISTINCT t.object_id)
            FROM sys.tables t
            JOIN sys.extended_properties ep ON t.object_id = ep.major_id AND ep.minor_id = 0
            WHERE t.is_ms_shipped = 0
              AND ep.class = 1
              AND (ep.name LIKE ''%[Mm]apping%'' OR ep.name LIKE ''%[Ss]ource%'' OR ep.name LIKE ''%[Ll]ineage%'' OR ep.name LIKE ''%[Ee]tl%'');

            SET @Pct = CASE WHEN @TotalTables = 0 THEN 100.00 ELSE (@MappedTables * 100.0) / @TotalTables END;

            SET @DbScore = CASE
                WHEN @Pct >= 75 THEN 3
                WHEN @Pct >= 25 THEN 2
                WHEN @Pct > 0 THEN 1
                ELSE 0
            END;

            SET @DbFinding = CASE
                WHEN @TotalTables = 0 THEN ''No user tables found.''
                ELSE CAST(@Pct AS NVARCHAR(10)) + ''% of tables have mapping documentation.''
            END;

            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
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