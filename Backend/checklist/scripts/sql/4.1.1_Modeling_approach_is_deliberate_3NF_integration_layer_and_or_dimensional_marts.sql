-- Checklist: Modeling approach is deliberate (3NF integration layer and/or dimensional marts)
-- Scope: DATABASE
-- Scoring: 0: <10% tables show deliberate patterns; 1: 10-30%; 2: 30-70%; 3: >70%. Proxy check; full architectural compliance requires human review.
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
    DECLARE @PatternTables INT;
    DECLARE @Pct DECIMAL(5,2);
    DECLARE @SampleTables NVARCHAR(MAX);

    SELECT 
        @TotalTables = COUNT(*),
        @PatternTables = SUM(CASE WHEN UPPER(t.name) LIKE ''DIM[_]%'' OR UPPER(t.name) LIKE ''FACT[_]%'' 
                                  OR UPPER(s.name) IN (''DW'',''MART'',''ODS'',''STG'',''INTEGRATION'',''RAW'',''LANDING'') 
                             THEN 1 ELSE 0 END)
    FROM sys.tables t
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE t.is_ms_shipped = 0;

    SET @Pct = CASE WHEN @TotalTables > 0 THEN (@PatternTables * 100.0) / @TotalTables ELSE 0 END;

    SELECT @SampleTables = STRING_AGG(s.name + ''.'' + t.name, '', '')
    FROM sys.tables t
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE t.is_ms_shipped = 0
      AND (UPPER(t.name) LIKE ''DIM[_]%'' OR UPPER(t.name) LIKE ''FACT[_]%'' 
           OR UPPER(s.name) IN (''DW'',''MART'',''ODS'',''STG'',''INTEGRATION'',''RAW'',''LANDING''))
    ORDER BY s.name, t.name;

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        ''' + QUOTENAME(@DbName) + N''',
        CASE 
            WHEN @TotalTables = 0 THEN 0
            WHEN @Pct >= 70 THEN 3
            WHEN @Pct >= 30 THEN 2
            WHEN @Pct >= 10 THEN 1
            ELSE 0 
        END,
        ''Total tables: '' + CAST(@TotalTables AS NVARCHAR) + '' | Pattern match: '' + CAST(@PatternTables AS NVARCHAR) + '' ('' + CAST(@Pct AS NVARCHAR) + ''%)'' + 
        CASE WHEN @SampleTables IS NOT NULL THEN '' | Examples: '' + @SampleTables ELSE '' | No matching tables found'' END
    );';
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
            DECLARE @TotalTables INT;
            DECLARE @PatternTables INT;
            DECLARE @Pct DECIMAL(5,2);
            DECLARE @SampleTables NVARCHAR(MAX);

            SELECT 
                @TotalTables = COUNT(*),
                @PatternTables = SUM(CASE WHEN UPPER(t.name) LIKE ''DIM[_]%'' OR UPPER(t.name) LIKE ''FACT[_]%'' 
                                          OR UPPER(s.name) IN (''DW'',''MART'',''ODS'',''STG'',''INTEGRATION'',''RAW'',''LANDING'') 
                                     THEN 1 ELSE 0 END)
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE t.is_ms_shipped = 0;

            SET @Pct = CASE WHEN @TotalTables > 0 THEN (@PatternTables * 100.0) / @TotalTables ELSE 0 END;

            SELECT @SampleTables = STRING_AGG(s.name + ''.'' + t.name, '', '')
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE t.is_ms_shipped = 0
              AND (UPPER(t.name) LIKE ''DIM[_]%'' OR UPPER(t.name) LIKE ''FACT[_]%'' 
                   OR UPPER(s.name) IN (''DW'',''MART'',''ODS'',''STG'',''INTEGRATION'',''RAW'',''LANDING''))
            ORDER BY s.name, t.name;

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (
                ''' + QUOTENAME(@DbName) + N''',
                CASE 
                    WHEN @TotalTables = 0 THEN 0
                    WHEN @Pct >= 70 THEN 3
                    WHEN @Pct >= 30 THEN 2
                    WHEN @Pct >= 10 THEN 1
                    ELSE 0 
                END,
                ''Total tables: '' + CAST(@TotalTables AS NVARCHAR) + '' | Pattern match: '' + CAST(@PatternTables AS NVARCHAR) + '' ('' + CAST(@Pct AS NVARCHAR) + ''%)'' + 
                CASE WHEN @SampleTables IS NOT NULL THEN '' | Examples: '' + @SampleTables ELSE '' | No matching tables found'' END
            );';
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