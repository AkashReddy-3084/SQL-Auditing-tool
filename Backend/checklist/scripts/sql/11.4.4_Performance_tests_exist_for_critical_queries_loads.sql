-- Checklist: Performance tests exist for critical queries/loads
-- Scope: DATABASE
-- Scoring: 0: No test-related objects found. 1: 1-4 objects found. 2: 5-9 objects found. 3: >=10 objects found.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @IsAzureSQLDB = 1
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @TestCount INT = 0;
    DECLARE @TestNames NVARCHAR(MAX) = '';

    SELECT @TestCount = COUNT(*),
           @TestNames = ISNULL(STRING_AGG(s.name + ''.'' + o.name, ''', ''), '''') WITHIN GROUP (ORDER BY s.name, o.name)
    FROM sys.objects o
    JOIN sys.schemas s ON o.schema_id = s.schema_id
    WHERE o.is_ms_shipped = 0
      AND o.type = ''P''
      AND (o.name LIKE ''%[Pp]erf%'' OR o.name LIKE ''%[Tt]est%'' OR o.name LIKE ''%[Bb]enchmark%'' OR o.name LIKE ''%[Ll]oad%'' OR o.name LIKE ''%[Ss]tress%'');

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        ''' + REPLACE(@DbName, '''', '''''') + ''',
        CASE WHEN @TestCount >= 10 THEN 3 WHEN @TestCount >= 5 THEN 2 WHEN @TestCount >= 1 THEN 1 ELSE 0 END,
        CASE WHEN @TestCount > 0 THEN ''Found '' + CAST(@TestCount AS NVARCHAR(10)) + '' test-related procedures: '' + @TestNames ELSE ''No test-related procedures found'' END
    );
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
            DECLARE @TestCount INT = 0;
            DECLARE @TestNames NVARCHAR(MAX) = '';

            SELECT @TestCount = COUNT(*),
                   @TestNames = ISNULL(STRING_AGG(s.name + ''.'' + o.name, ''', ''), '''') WITHIN GROUP (ORDER BY s.name, o.name)
            FROM sys.objects o
            JOIN sys.schemas s ON o.schema_id = s.schema_id
            WHERE o.is_ms_shipped = 0
              AND o.type = ''P''
              AND (o.name LIKE ''%[Pp]erf%'' OR o.name LIKE ''%[Tt]est%'' OR o.name LIKE ''%[Bb]enchmark%'' OR o.name LIKE ''%[Ll]oad%'' OR o.name LIKE ''%[Ss]tress%'');

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (
                ''' + REPLACE(@DbName, '''', '''''') + ''',
                CASE WHEN @TestCount >= 10 THEN 3 WHEN @TestCount >= 5 THEN 2 WHEN @TestCount >= 1 THEN 1 ELSE 0 END,
                CASE WHEN @TestCount > 0 THEN ''Found '' + CAST(@TestCount AS NVARCHAR(10)) + '' test-related procedures: '' + @TestNames ELSE ''No test-related procedures found'' END
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