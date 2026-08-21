-- Checklist: NOT NULL applied to mandatory columns
-- Scope: DATABASE
-- Scoring: 3 if zero nullable columns found; 2 if 1-5 nullable columns; 1 if 6-20; 0 if >20 or evaluation fails.

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
    DECLARE @NullableCols NVARCHAR(MAX);
    DECLARE @Count INT;

    SELECT @NullableCols = STRING_AGG(s.name + ''.'' + t.name + ''.'' + c.name, '', ''),
           @Count = COUNT(*)
    FROM sys.columns c
    JOIN sys.tables t ON c.object_id = t.object_id
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'')
      AND t.is_ms_shipped = 0
      AND c.is_nullable = 1
      AND c.is_identity = 0
      AND c.is_computed = 0;

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        DB_NAME(),
        CASE
            WHEN @Count = 0 THEN 3
            WHEN @Count BETWEEN 1 AND 5 THEN 2
            WHEN @Count BETWEEN 6 AND 20 THEN 1
            ELSE 0
        END,
        ISNULL(@NullableCols, ''No nullable columns found'')
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
            DECLARE @NullableCols NVARCHAR(MAX);
            DECLARE @Count INT;

            SELECT @NullableCols = STRING_AGG(s.name + ''.'' + t.name + ''.'' + c.name, '', ''),
                   @Count = COUNT(*)
            FROM sys.columns c
            JOIN sys.tables t ON c.object_id = t.object_id
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'')
              AND t.is_ms_shipped = 0
              AND c.is_nullable = 1
              AND c.is_identity = 0
              AND c.is_computed = 0;

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (
                ''' + REPLACE(@DbName, '''', '''''') + N''',
                CASE
                    WHEN @Count = 0 THEN 3
                    WHEN @Count BETWEEN 1 AND 5 THEN 2
                    WHEN @Count BETWEEN 6 AND 20 THEN 1
                    ELSE 0
                END,
                ISNULL(@NullableCols, ''No nullable columns found'')
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