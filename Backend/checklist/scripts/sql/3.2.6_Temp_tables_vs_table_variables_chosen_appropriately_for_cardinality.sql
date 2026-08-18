-- Checklist: Temp tables vs table variables chosen appropriately for cardinality
-- Scope: DATABASE
-- Scoring: 3: No table variables found. 2: Table variables found (requires human review for cardinality validation). 1: Table variables used in complex joins/inserts. 0: Evaluation failed or widespread misuse.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 3;
DECLARE @Result NVARCHAR(10) = 'Pass';
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
    -- Azure SQL Database: evaluate current DB only
    SET @DbName = DB_NAME();
    SET @Sql = N'
        SELECT 
            DbName = ''' + QUOTENAME(@DbName) + N''',
            DbScore = CASE 
                WHEN COUNT(*) = 0 THEN 3
                WHEN SUM(CASE WHEN definition LIKE ''%JOIN @%'' OR definition LIKE ''%INSERT INTO @%'' THEN 1 ELSE 0 END) > 0 THEN 1
                ELSE 2 
            END,
            Finding = ISNULL(STRING_AGG(ISNULL(QUOTENAME(OBJECT_SCHEMA_NAME(object_id)), ''dbo'') + ''.'' + QUOTENAME(name), '', ''), ''No table variables found'')
        FROM sys.sql_modules m
        JOIN sys.objects o ON m.object_id = o.object_id
        WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'')
          AND m.definition LIKE ''%DECLARE @%TABLE%'';
    ';
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user DBs
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
            SELECT 
                DbName = ''' + QUOTENAME(@DbName) + N''',
                DbScore = CASE 
                    WHEN COUNT(*) = 0 THEN 3
                    WHEN SUM(CASE WHEN definition LIKE ''%JOIN @%'' OR definition LIKE ''%INSERT INTO @%'' THEN 1 ELSE 0 END) > 0 THEN 1
                    ELSE 2 
                END,
                Finding = ISNULL(STRING_AGG(ISNULL(QUOTENAME(OBJECT_SCHEMA_NAME(object_id)), ''dbo'') + ''.'' + QUOTENAME(name), '', ''), ''No table variables found'')
            FROM sys.sql_modules m
            JOIN sys.objects o ON m.object_id = o.object_id
            WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'')
              AND m.definition LIKE ''%DECLARE @%TABLE%'';
            ';
            INSERT INTO #DbResults (DbName, DbScore, Finding)
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

-- Cap score at 2 if table variables are present, as cardinality assessment requires human judgment
IF @Score = 3 AND EXISTS (SELECT 1 FROM #DbResults WHERE Finding <> 'No table variables found')
BEGIN
    SET @Score = 2;
    SET @Finding = @Finding + CHAR(13) + CHAR(10) + '-- NOTE: This script provides automated evidence. Full compliance requires human review.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;