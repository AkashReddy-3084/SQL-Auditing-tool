-- Checklist: Table/column definitions documented with business context
-- Scope: DATABASE
-- Scoring: 3: 100% documented. 2: >=90% documented. 1: >=10% documented. 0: <10% documented.

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
        DECLARE @TotalTables INT, @TotalColumns INT, @DocTables INT, @DocColumns INT;
        SELECT @TotalTables = COUNT(*) FROM sys.tables;
        SELECT @TotalColumns = COUNT(*) FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id;
        SELECT @DocTables = COUNT(*) FROM sys.tables t WHERE EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE ep.major_id = t.object_id AND ep.minor_id = 0 AND ep.name = ''MS_Description'');
        SELECT @DocColumns = COUNT(*) FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE ep.major_id = t.object_id AND ep.minor_id = c.column_id AND ep.name = ''MS_Description'');
        
        DECLARE @Total INT = @TotalTables + @TotalColumns;
        DECLARE @Doc INT = @DocTables + @DocColumns;
        DECLARE @Pct FLOAT = CASE WHEN @Total = 0 THEN 100.0 ELSE CAST(@Doc AS FLOAT) / @Total * 100.0 END;
        
        DECLARE @DbScore INT = CASE 
            WHEN @Pct >= 100 THEN 3
            WHEN @Pct >= 90 THEN 2
            WHEN @Pct >= 10 THEN 1
            ELSE 0
        END;
        
        DECLARE @DbFinding NVARCHAR(MAX) = CAST(@Pct AS NVARCHAR(10)) + ''% documented ('' + CAST(@Doc AS NVARCHAR(10)) + ''/'' + CAST(@Total AS NVARCHAR(10)) + '')'';
        
        IF @DbScore < 2
        BEGIN
            DECLARE @Missing NVARCHAR(MAX) = (SELECT STRING_AGG(s.name + ''.'' + t.name, '', '') FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE NOT EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE ep.major_id = t.object_id AND ep.minor_id = 0 AND ep.name = ''MS_Description'') ORDER BY s.name, t.name);
            IF @Missing IS NOT NULL SET @DbFinding = @DbFinding + '' | Missing table docs: '' + LEFT(@Missing, 500);
        END;
        
        INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @DbFinding);
    ';
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
            DECLARE @TotalTables INT, @TotalColumns INT, @DocTables INT, @DocColumns INT;
            SELECT @TotalTables = COUNT(*) FROM sys.tables;
            SELECT @TotalColumns = COUNT(*) FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id;
            SELECT @DocTables = COUNT(*) FROM sys.tables t WHERE EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE ep.major_id = t.object_id AND ep.minor_id = 0 AND ep.name = ''MS_Description'');
            SELECT @DocColumns = COUNT(*) FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE ep.major_id = t.object_id AND ep.minor_id = c.column_id AND ep.name = ''MS_Description'');
            
            DECLARE @Total INT = @TotalTables + @TotalColumns;
            DECLARE @Doc INT = @DocTables + @DocColumns;
            DECLARE @Pct FLOAT = CASE WHEN @Total = 0 THEN 100.0 ELSE CAST(@Doc AS FLOAT) / @Total * 100.0 END;
            
            DECLARE @DbScore INT = CASE 
                WHEN @Pct >= 100 THEN 3
                WHEN @Pct >= 90 THEN 2
                WHEN @Pct >= 10 THEN 1
                ELSE 0
            END;
            
            DECLARE @DbFinding NVARCHAR(MAX) = CAST(@Pct AS NVARCHAR(10)) + ''% documented ('' + CAST(@Doc AS NVARCHAR(10)) + ''/'' + CAST(@Total AS NVARCHAR(10)) + '')'';
            
            IF @DbScore < 2
            BEGIN
                DECLARE @Missing NVARCHAR(MAX) = (SELECT STRING_AGG(s.name + ''.'' + t.name, '', '') FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE NOT EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE ep.major_id = t.object_id AND ep.minor_id = 0 AND ep.name = ''MS_Description'') ORDER BY s.name, t.name);
                IF @Missing IS NOT NULL SET @DbFinding = @DbFinding + '' | Missing table docs: '' + LEFT(@Missing, 500);
            END;
            
            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @DbFinding);
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