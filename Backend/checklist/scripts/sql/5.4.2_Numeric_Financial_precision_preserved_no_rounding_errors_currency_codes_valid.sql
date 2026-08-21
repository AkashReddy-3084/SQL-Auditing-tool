-- Checklist: Numeric / Financial: precision preserved; no rounding errors; currency codes valid
-- Scope: DATABASE
-- Scoring: 3=Fully compliant types/lengths; 2=Minor currency type gaps; 1=Float/Real in financial cols; 0=Int/BigInt in financial cols

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

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @DbScore INT = 3;
    DECLARE @DbFinding NVARCHAR(MAX) = '''';
    DECLARE @FloatCols NVARCHAR(MAX) = '''';
    DECLARE @IntCols NVARCHAR(MAX) = '''';
    DECLARE @CurrencyCols NVARCHAR(MAX) = '''';

    SELECT @FloatCols = STRING_AGG(s.name + ''.'' + t.name + ''.'' + c.name, '', '')
    FROM sys.columns c
    JOIN sys.types ty ON c.user_type_id = ty.user_type_id
    JOIN sys.tables t ON c.object_id = t.object_id
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE ty.name IN (''float'', ''real'')
      AND (c.name LIKE ''%amount%'' OR c.name LIKE ''%price%'' OR c.name LIKE ''%cost%'' OR c.name LIKE ''%balance%'' OR c.name LIKE ''%revenue%'' OR c.name LIKE ''%expense%'' OR c.name LIKE ''%fee%'' OR c.name LIKE ''%tax%'' OR c.name LIKE ''%money%'');

    SELECT @IntCols = STRING_AGG(s.name + ''.'' + t.name + ''.'' + c.name, '', '')
    FROM sys.columns c
    JOIN sys.types ty ON c.user_type_id = ty.user_type_id
    JOIN sys.tables t ON c.object_id = t.object_id
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE ty.name IN (''int'', ''bigint'')
      AND (c.name LIKE ''%amount%'' OR c.name LIKE ''%price%'' OR c.name LIKE ''%cost%'' OR c.name LIKE ''%balance%'' OR c.name LIKE ''%revenue%'' OR c.name LIKE ''%expense%'' OR c.name LIKE ''%fee%'' OR c.name LIKE ''%tax%'' OR c.name LIKE ''%money%'');

    SELECT @CurrencyCols = STRING_AGG(s.name + ''.'' + t.name + ''.'' + c.name, '', '')
    FROM sys.columns c
    JOIN sys.types ty ON c.user_type_id = ty.user_type_id
    JOIN sys.tables t ON c.object_id = t.object_id
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE (c.name LIKE ''%currency%'' OR c.name LIKE ''%curr%'')
      AND (ty.name NOT IN (''char'', ''varchar'') OR c.max_length <> 3);

    IF LEN(@IntCols) > 0 SET @DbScore = 0;
    ELSE IF LEN(@FloatCols) > 0 SET @DbScore = 1;
    ELSE IF LEN(@CurrencyCols) > 0 SET @DbScore = 2;

    SET @DbFinding = CASE @DbScore
        WHEN 3 THEN ''No non-compliant objects found''
        WHEN 2 THEN ''Currency columns lack valid type/length: '' + @CurrencyCols
        WHEN 1 THEN ''Float/Real used for financial data: '' + @FloatCols
        WHEN 0 THEN ''Int/BigInt used for financial data: '' + @IntCols
    END;

    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + @DbName + ''', @DbScore, @DbFinding);';
    EXEC sp_executesql @Sql;
END
ELSE -- SQL Server / Azure SQL MI
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
            DECLARE @DbScore INT = 3;
            DECLARE @DbFinding NVARCHAR(MAX) = '''';
            DECLARE @FloatCols NVARCHAR(MAX) = '''';
            DECLARE @IntCols NVARCHAR(MAX) = '''';
            DECLARE @CurrencyCols NVARCHAR(MAX) = '''';

            SELECT @FloatCols = STRING_AGG(s.name + ''.'' + t.name + ''.'' + c.name, '', '')
            FROM sys.columns c
            JOIN sys.types ty ON c.user_type_id = ty.user_type_id
            JOIN sys.tables t ON c.object_id = t.object_id
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE ty.name IN (''float'', ''real'')
              AND (c.name LIKE ''%amount%'' OR c.name LIKE ''%price%'' OR c.name LIKE ''%cost%'' OR c.name LIKE ''%balance%'' OR c.name LIKE ''%revenue%'' OR c.name LIKE ''%expense%'' OR c.name LIKE ''%fee%'' OR c.name LIKE ''%tax%'' OR c.name LIKE ''%money%'');

            SELECT @IntCols = STRING_AGG(s.name + ''.'' + t.name + ''.'' + c.name, '', '')
            FROM sys.columns c
            JOIN sys.types ty ON c.user_type_id = ty.user_type_id
            JOIN sys.tables t ON c.object_id = t.object_id
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE ty.name IN (''int'', ''bigint'')
              AND (c.name LIKE ''%amount%'' OR c.name LIKE ''%price%'' OR c.name LIKE ''%cost%'' OR c.name LIKE ''%balance%'' OR c.name LIKE ''%revenue%'' OR c.name LIKE ''%expense%'' OR c.name LIKE ''%fee%'' OR c.name LIKE ''%tax%'' OR c.name LIKE ''%money%'');

            SELECT @CurrencyCols = STRING_AGG(s.name + ''.'' + t.name + ''.'' + c.name, '', '')
            FROM sys.columns c
            JOIN sys.types ty ON c.user_type_id = ty.user_type_id
            JOIN sys.tables t ON c.object_id = t.object_id
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE (c.name LIKE ''%currency%'' OR c.name LIKE ''%curr%'')
              AND (ty.name NOT IN (''char'', ''varchar'') OR c.max_length <> 3);

            IF LEN(@IntCols) > 0 SET @DbScore = 0;
            ELSE IF LEN(@FloatCols) > 0 SET @DbScore = 1;
            ELSE IF LEN(@CurrencyCols) > 0 SET @DbScore = 2;

            SET @DbFinding = CASE @DbScore
                WHEN 3 THEN ''No non-compliant objects found''
                WHEN 2 THEN ''Currency columns lack valid type/length: '' + @CurrencyCols
                WHEN 1 THEN ''Float/Real used for financial data: '' + @FloatCols
                WHEN 0 THEN ''Int/BigInt used for financial data: '' + @IntCols
            END;

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