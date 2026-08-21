-- Checklist: Fact tables contain only foreign keys and measures (no descriptive attributes)
-- Scope: DATABASE
-- Scoring: 3=0 violations, 2=1-2 violations, 1=3-5 violations, 0=>5 violations across all evaluated fact tables.

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
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    SELECT
        ''' + @DbName + ''' AS DbName,
        CASE
            WHEN COUNT(*) = 0 THEN 3
            WHEN COUNT(*) <= 2 THEN 2
            WHEN COUNT(*) <= 5 THEN 1
            ELSE 0
        END AS DbScore,
        CASE
            WHEN COUNT(*) = 0 THEN ''No non-compliant objects found''
            ELSE STRING_AGG(s.name + ''.'' + t.name + ''.'' + c.name + '' ('' + ty.name + '')'', '', '')
        END AS Finding
    FROM sys.tables t
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    JOIN sys.columns c ON t.object_id = c.object_id
    JOIN sys.types ty ON c.user_type_id = ty.user_type_id
    LEFT JOIN sys.foreign_key_columns fkc ON fkc.parent_object_id = t.object_id AND fkc.parent_column_id = c.column_id
    WHERE (t.name LIKE ''Fact%'' OR t.name LIKE ''fact%'' OR EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE ep.major_id = t.object_id AND ep.minor_id = 0 AND ep.name = ''IsFactTable'' AND ep.value = 1))
      AND ty.name IN (''varchar'', ''nvarchar'', ''char'', ''nchar'', ''text'', ''ntext'')
      AND fkc.constraint_object_id IS NULL
      AND c.is_computed = 0;
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate all online user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            SELECT
                ''' + @DbName + ''' AS DbName,
                CASE
                    WHEN COUNT(*) = 0 THEN 3
                    WHEN COUNT(*) <= 2 THEN 2
                    WHEN COUNT(*) <= 5 THEN 1
                    ELSE 0
                END AS DbScore,
                CASE
                    WHEN COUNT(*) = 0 THEN ''No non-compliant objects found''
                    ELSE STRING_AGG(s.name + ''.'' + t.name + ''.'' + c.name + '' ('' + ty.name + '')'', '', '')
                END AS Finding
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            JOIN sys.columns c ON t.object_id = c.object_id
            JOIN sys.types ty ON c.user_type_id = ty.user_type_id
            LEFT JOIN sys.foreign_key_columns fkc ON fkc.parent_object_id = t.object_id AND fkc.parent_column_id = c.column_id
            WHERE (t.name LIKE ''Fact%'' OR t.name LIKE ''fact%'' OR EXISTS (SELECT 1 FROM sys.extended_properties ep WHERE ep.major_id = t.object_id AND ep.minor_id = 0 AND ep.name = ''IsFactTable'' AND ep.value = 1))
              AND ty.name IN (''varchar'', ''nvarchar'', ''char'', ''nchar'', ''text'', ''ntext'')
              AND fkc.constraint_object_id IS NULL
              AND c.is_computed = 0;
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

SET @DatabaseQueried = (SELECT STRING_AGG(DbName, ', ') FROM #DbResults);

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