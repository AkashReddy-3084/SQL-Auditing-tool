-- Checklist: Parameter sniffing issues identified and mitigated (OPTIMIZE FOR, recompile, etc.)
-- Scope: DATABASE
-- Scoring: 0: No mitigation hints found. 1: 1-9 hints. 2: 10-49 hints. 3: 50+ hints. Overall score uses MIN across databases.

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
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT ''' + @DbName + ''' AS DbName,
           CASE WHEN COUNT(*) = 0 THEN 0
                WHEN COUNT(*) BETWEEN 1 AND 9 THEN 1
                WHEN COUNT(*) BETWEEN 10 AND 49 THEN 2
                ELSE 3 END AS DbScore,
           CASE WHEN COUNT(*) = 0 THEN ''No mitigation hints found.''
                ELSE ''Found '' + CAST(COUNT(*) AS NVARCHAR) + '' hints. Examples: '' + STRING_AGG(SCHEMA_NAME(o.schema_id) + ''.'' + o.name, '', '') WITHIN GROUP (ORDER BY o.name)
           END AS Finding
    FROM sys.sql_modules m
    JOIN sys.objects o ON m.object_id = o.object_id
    WHERE o.type IN (''P'', ''TF'', ''IF'', ''FS'', ''FT'')
      AND m.definition IS NOT NULL
      AND (m.definition LIKE ''%RECOMPILE%'' OR m.definition LIKE ''%OPTIMIZE FOR%'');
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
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            SELECT ''' + @DbName + ''' AS DbName,
                   CASE WHEN COUNT(*) = 0 THEN 0
                        WHEN COUNT(*) BETWEEN 1 AND 9 THEN 1
                        WHEN COUNT(*) BETWEEN 10 AND 49 THEN 2
                        ELSE 3 END AS DbScore,
                   CASE WHEN COUNT(*) = 0 THEN ''No mitigation hints found.''
                        ELSE ''Found '' + CAST(COUNT(*) AS NVARCHAR) + '' hints. Examples: '' + STRING_AGG(SCHEMA_NAME(o.schema_id) + ''.'' + o.name, '', '') WITHIN GROUP (ORDER BY o.name)
                   END AS Finding
            FROM sys.sql_modules m
            JOIN sys.objects o ON m.object_id = o.object_id
            WHERE o.type IN (''P'', ''TF'', ''IF'', ''FS'', ''FT'')
              AND m.definition IS NOT NULL
              AND (m.definition LIKE ''%RECOMPILE%'' OR m.definition LIKE ''%OPTIMIZE FOR%'');
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