-- Checklist: Date/Time dimension exists with required attributes
-- Scope: DATABASE
-- Scoring: 0=No candidate table found; 1=Table found, 0-2 required attributes; 2=Table found, 3-5 required attributes; 3=Table found, 6+ required attributes

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
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
    DECLARE @BestTable NVARCHAR(128) = NULL;
    DECLARE @MaxMatch INT = 0;
    DECLARE @MissingCols NVARCHAR(MAX) = '''';
    DECLARE @RequiredCols TABLE (ColName NVARCHAR(128));
    INSERT INTO @RequiredCols VALUES (''DateKey''), (''FullDate''), (''Year''), (''Quarter''), (''Month''), (''Day''), (''DayOfWeek''), (''IsWeekday''), (''IsHoliday'');

    SELECT @BestTable = t.name, @MaxMatch = COUNT(c.name)
    FROM sys.tables t
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    CROSS APPLY (
        SELECT COUNT(*) FROM sys.columns c WHERE c.object_id = t.object_id AND c.name IN (''DateKey'', ''FullDate'', ''Year'', ''Quarter'', ''Month'', ''Day'', ''DayOfWeek'', ''IsWeekday'', ''IsHoliday'')
    ) AS cnt
    WHERE t.name LIKE ''%Date%'' OR t.name LIKE ''%DimDate%'' OR t.name LIKE ''%Calendar%''
    GROUP BY t.name
    ORDER BY @MaxMatch DESC;

    IF @BestTable IS NOT NULL
    BEGIN
        SELECT @MissingCols = STRING_AGG(rc.ColName, '', '')
        FROM @RequiredCols rc
        WHERE NOT EXISTS (
            SELECT 1 FROM sys.columns c WHERE c.object_id = OBJECT_ID(@BestTable) AND c.name = rc.ColName
        );
        
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (
            ''' + QUOTENAME(@DbName) + N''',
            CASE WHEN @MaxMatch >= 6 THEN 3 WHEN @MaxMatch >= 3 THEN 2 WHEN @MaxMatch >= 1 THEN 1 ELSE 0 END,
            @BestTable + N': ' + CAST(@MaxMatch AS NVARCHAR(10)) + N''/9 required attributes found. Missing: '' + ISNULL(@MissingCols, ''None'')
        );
    END
    ELSE
    BEGIN
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (''' + QUOTENAME(@DbName) + N''', 0, ''No Date/Time dimension table found'');
    END
    ';
    
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @BestTable NVARCHAR(128) = NULL;
            DECLARE @MaxMatch INT = 0;
            DECLARE @MissingCols NVARCHAR(MAX) = '''';
            DECLARE @RequiredCols TABLE (ColName NVARCHAR(128));
            INSERT INTO @RequiredCols VALUES (''DateKey''), (''FullDate''), (''Year''), (''Quarter''), (''Month''), (''Day''), (''DayOfWeek''), (''IsWeekday''), (''IsHoliday'');

            SELECT @BestTable = t.name, @MaxMatch = COUNT(c.name)
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            CROSS APPLY (
                SELECT COUNT(*) FROM sys.columns c WHERE c.object_id = t.object_id AND c.name IN (''DateKey'', ''FullDate'', ''Year'', ''Quarter'', ''Month'', ''Day'', ''DayOfWeek'', ''IsWeekday'', ''IsHoliday'')
            ) AS cnt
            WHERE t.name LIKE ''%Date%'' OR t.name LIKE ''%DimDate%'' OR t.name LIKE ''%Calendar%''
            GROUP BY t.name
            ORDER BY @MaxMatch DESC;

            IF @BestTable IS NOT NULL
            BEGIN
                SELECT @MissingCols = STRING_AGG(rc.ColName, '', '')
                FROM @RequiredCols rc
                WHERE NOT EXISTS (
                    SELECT 1 FROM sys.columns c WHERE c.object_id = OBJECT_ID(@BestTable) AND c.name = rc.ColName
                );
                
                INSERT INTO #DbResults (DbName, DbScore, Finding)
                VALUES (
                    ''' + QUOTENAME(@DbName) + N''',
                    CASE WHEN @MaxMatch >= 6 THEN 3 WHEN @MaxMatch >= 3 THEN 2 WHEN @MaxMatch >= 1 THEN 1 ELSE 0 END,
                    @BestTable + N': ' + CAST(@MaxMatch AS NVARCHAR(10)) + N''/9 required attributes found. Missing: '' + ISNULL(@MissingCols, ''None'')
                );
            END
            ELSE
            BEGIN
                INSERT INTO #DbResults (DbName, DbScore, Finding)
                VALUES (''' + QUOTENAME(@DbName) + N''', 0, ''No Date/Time dimension table found'');
            END
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
        WHERE Finding IS NOT NULL AND Finding <> ''
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