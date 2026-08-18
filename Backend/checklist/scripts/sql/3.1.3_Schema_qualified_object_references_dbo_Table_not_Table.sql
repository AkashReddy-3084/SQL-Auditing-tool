-- Checklist: Schema-qualified object references (dbo.Table, not Table)
-- Scope: DATABASE
-- Scoring: 3=0 unqualified refs, 2=1-5, 1=6-20, 0=>20

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
    -- Azure SQL Database: evaluate current DB only
    SET @DbName = DB_NAME();
    SET @Sql = N'
        DECLARE @TotalUnqualified INT;
        DECLARE @FindingText NVARCHAR(MAX);

        SELECT @TotalUnqualified = SUM(cnt),
               @FindingText = STRING_AGG(mod, '','')
        FROM (
            SELECT o.name AS mod, COUNT(*) AS cnt
            FROM sys.sql_expression_dependencies sed
            JOIN sys.objects o ON sed.referencing_id = o.object_id
            WHERE sed.referenced_schema_name IS NULL
              AND sed.class = 1
              AND o.type IN (''P'',''FN'',''IF'',''TF'',''V'',''TR'')
            GROUP BY o.name
        ) AS t;

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (
            DB_NAME(),
            CASE
                WHEN @TotalUnqualified IS NULL OR @TotalUnqualified = 0 THEN 3
                WHEN @TotalUnqualified <= 5 THEN 2
                WHEN @TotalUnqualified <= 20 THEN 1
                ELSE 0
            END,
            ISNULL(@FindingText, ''No non-compliant objects found'')
        );
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user DBs
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
            DECLARE @TotalUnqualified INT;
            DECLARE @FindingText NVARCHAR(MAX);

            SELECT @TotalUnqualified = SUM(cnt),
                   @FindingText = STRING_AGG(mod, '','')
            FROM (
                SELECT o.name AS mod, COUNT(*) AS cnt
                FROM sys.sql_expression_dependencies sed
                JOIN sys.objects o ON sed.referencing_id = o.object_id
                WHERE sed.referenced_schema_name IS NULL
                  AND sed.class = 1
                  AND o.type IN (''P'',''FN'',''IF'',''TF'',''V'',''TR'')
                GROUP BY o.name
            ) AS t;

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (
                ''' + REPLACE(@DbName, '''', '''''') + N''',
                CASE
                    WHEN @TotalUnqualified IS NULL OR @TotalUnqualified = 0 THEN 3
                    WHEN @TotalUnqualified <= 5 THEN 2
                    WHEN @TotalUnqualified <= 20 THEN 1
                    ELSE 0
                END,
                ISNULL(@FindingText, ''No non-compliant objects found'')
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
          AND Finding <> 'No non-compliant objects found'
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