-- Checklist: Foreign keys enforced where integrity matters (or documented trusted-by-ETL exceptions)
-- Scope: DATABASE
-- Scoring: 3 = No disabled foreign keys found; 0 = Disabled foreign keys found (requires human review for ETL exceptions)
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

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
        DECLARE @DisabledFks NVARCHAR(MAX);
        SELECT @DisabledFks = STRING_AGG(s.name + ''.'' + fk.name, '', '')
        FROM sys.foreign_keys fk
        JOIN sys.schemas s ON fk.schema_id = s.schema_id
        WHERE fk.is_disabled = 1;

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (
            ''' + REPLACE(@DbName, '''', '''''') + N''',
            CASE WHEN @DisabledFks IS NULL THEN 3 ELSE 0 END,
            ISNULL(@DisabledFks, ''No disabled foreign keys found'')
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
                DECLARE @DisabledFks NVARCHAR(MAX);
                SELECT @DisabledFks = STRING_AGG(s.name + ''.'' + fk.name, '', '')
                FROM sys.foreign_keys fk
                JOIN sys.schemas s ON fk.schema_id = s.schema_id
                WHERE fk.is_disabled = 1;

                INSERT INTO #DbResults (DbName, DbScore, Finding)
                VALUES (
                    ''' + REPLACE(@DbName, '''', '''''') + N''',
                    CASE WHEN @DisabledFks IS NULL THEN 3 ELSE 0 END,
                    ISNULL(@DisabledFks, ''No disabled foreign keys found'')
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