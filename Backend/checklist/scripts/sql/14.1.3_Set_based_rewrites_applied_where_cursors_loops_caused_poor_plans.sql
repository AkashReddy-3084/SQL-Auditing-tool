-- Checklist: Set-based rewrites applied where cursors/loops caused poor plans
-- Scope: DATABASE
-- Scoring: 3: No modules use CURSOR or WHILE. 2: 1-2 modules use them. 1: 3-5 modules use them. 0: >5 modules use them.

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
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
    DECLARE @Count INT;
    DECLARE @Names NVARCHAR(MAX);
    SELECT @Count = COUNT(*),
           @Names = STRING_AGG(QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + ''.'' + QUOTENAME(name), '', '')
    FROM sys.sql_modules m
    JOIN sys.objects o ON m.object_id = o.object_id
    WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'')
      AND (m.definition LIKE ''%CURSOR%'' OR m.definition LIKE ''%WHILE%'');

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (''' + @DbName + ''',
            CASE WHEN @Count = 0 THEN 3
                 WHEN @Count <= 2 THEN 2
                 WHEN @Count <= 5 THEN 1
                 ELSE 0 END,
            CASE WHEN @Count = 0 THEN ''No non-compliant objects found''
                 ELSE @Names END);
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
            DECLARE @Count INT;
            DECLARE @Names NVARCHAR(MAX);
            SELECT @Count = COUNT(*),
                   @Names = STRING_AGG(QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + ''.'' + QUOTENAME(name), '', '')
            FROM sys.sql_modules m
            JOIN sys.objects o ON m.object_id = o.object_id
            WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'')
              AND (m.definition LIKE ''%CURSOR%'' OR m.definition LIKE ''%WHILE%'');

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + @DbName + ''',
                    CASE WHEN @Count = 0 THEN 3
                         WHEN @Count <= 2 THEN 2
                         WHEN @Count <= 5 THEN 1
                         ELSE 0 END,
                    CASE WHEN @Count = 0 THEN ''No non-compliant objects found''
                         ELSE @Names END);
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