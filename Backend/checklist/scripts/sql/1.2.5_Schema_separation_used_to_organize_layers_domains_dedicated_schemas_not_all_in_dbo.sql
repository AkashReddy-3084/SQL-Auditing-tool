-- Checklist: Schema separation used to organize layers/domains (dedicated schemas, not all in dbo)
-- Scope: DATABASE
-- Scoring: 3=Pass (>=2 non-dbo schemas contain user objects), 2=Mostly Pass (exactly 1 non-dbo schema contains objects), 1=Partial Pass (non-dbo schemas exist but are empty), 0=Fail (all user objects reside exclusively in dbo)

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
    -- Azure SQL Database: evaluate current connected database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
        DECLARE @NonDboSchemas INT;
        DECLARE @TotalObjects INT;
        DECLARE @SchemasList NVARCHAR(MAX);

        SELECT
            @NonDboSchemas = COUNT(DISTINCT CASE WHEN s.name <> ''dbo'' THEN s.name END),
            @TotalObjects = COUNT(o.object_id),
            @SchemasList = STRING_AGG(DISTINCT CASE WHEN s.name <> ''dbo'' THEN s.name END, '', '')
        FROM sys.objects o
        JOIN sys.schemas s ON o.schema_id = s.schema_id
        WHERE o.is_ms_shipped = 0
          AND o.type IN (''U'', ''V'', ''P'', ''FN'', ''IF'', ''TF'')
          AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'');

        DECLARE @DbScore INT;
        DECLARE @DbFinding NVARCHAR(MAX);

        IF @TotalObjects = 0
        BEGIN
            SET @DbScore = 3;
            SET @DbFinding = ''No user objects found (empty database).'';
        END
        ELSE IF @NonDboSchemas >= 2
        BEGIN
            SET @DbScore = 3;
            SET @DbFinding = ''Objects distributed across '' + CAST(@NonDboSchemas AS NVARCHAR(10)) + '' non-dbo schemas: '' + ISNULL(@SchemasList, ''none'');
        END
        ELSE IF @NonDboSchemas = 1
        BEGIN
            SET @DbScore = 2;
            SET @DbFinding = ''Objects in 1 non-dbo schema: '' + ISNULL(@SchemasList, ''none'');
        END
        ELSE IF @NonDboSchemas = 0 AND EXISTS (SELECT 1 FROM sys.schemas WHERE name <> ''dbo'' AND name NOT IN (''sys'', ''INFORMATION_SCHEMA''))
        BEGIN
            SET @DbScore = 1;
            SET @DbFinding = ''Non-dbo schemas exist but contain no user objects.'';
        END
        ELSE
        BEGIN
            SET @DbScore = 0;
            SET @DbFinding = ''All '' + CAST(@TotalObjects AS NVARCHAR(10)) + '' user objects reside exclusively in dbo schema.'';
        END

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (' + QUOTENAME(@DbName, '''') + ', @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate all online user databases
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
            DECLARE @NonDboSchemas INT;
            DECLARE @TotalObjects INT;
            DECLARE @SchemasList NVARCHAR(MAX);

            SELECT
                @NonDboSchemas = COUNT(DISTINCT CASE WHEN s.name <> ''dbo'' THEN s.name END),
                @TotalObjects = COUNT(o.object_id),
                @SchemasList = STRING_AGG(DISTINCT CASE WHEN s.name <> ''dbo'' THEN s.name END, '', '')
            FROM sys.objects o
            JOIN sys.schemas s ON o.schema_id = s.schema_id
            WHERE o.is_ms_shipped = 0
              AND o.type IN (''U'', ''V'', ''P'', ''FN'', ''IF'', ''TF'')
              AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'');

            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            IF @TotalObjects = 0
            BEGIN
                SET @DbScore = 3;
                SET @DbFinding = ''No user objects found (empty database).'';
            END
            ELSE IF @NonDboSchemas >= 2
            BEGIN
                SET @DbScore = 3;
                SET @DbFinding = ''Objects distributed across '' + CAST(@NonDboSchemas AS NVARCHAR(10)) + '' non-dbo schemas: '' + ISNULL(@SchemasList, ''none'');
            END
            ELSE IF @NonDboSchemas = 1
            BEGIN
                SET @DbScore = 2;
                SET @DbFinding = ''Objects in 1 non-dbo schema: '' + ISNULL(@SchemasList, ''none'');
            END
            ELSE IF @NonDboSchemas = 0 AND EXISTS (SELECT 1 FROM sys.schemas WHERE name <> ''dbo'' AND name NOT IN (''sys'', ''INFORMATION_SCHEMA''))
            BEGIN
                SET @DbScore = 1;
                SET @DbFinding = ''Non-dbo schemas exist but contain no user objects.'';
            END
            ELSE
            BEGIN
                SET @DbScore = 0;
                SET @DbFinding = ''All '' + CAST(@TotalObjects AS NVARCHAR(10)) + '' user objects reside exclusively in dbo schema.'';
            END

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (' + QUOTENAME(@DbName, '''') + ', @DbScore, @DbFinding);
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