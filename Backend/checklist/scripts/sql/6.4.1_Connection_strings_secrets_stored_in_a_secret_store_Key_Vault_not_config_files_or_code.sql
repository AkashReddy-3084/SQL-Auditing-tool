-- Checklist: Connection strings/secrets stored in a secret store (Key Vault), not config files or code
-- Scope: DATABASE
-- Scoring: 3: No hardcoded secrets/connection strings detected. 2: 1-2 objects detected. 1: 3-5 objects detected. 0: >5 objects detected.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

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
        DECLARE @Count INT;
        DECLARE @ObjList NVARCHAR(MAX);
        SELECT @Count = COUNT(*),
               @ObjList = STRING_AGG(QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + ''.'' + QUOTENAME(OBJECT_NAME(object_id)), '', '')
        FROM sys.sql_modules m
        JOIN sys.objects o ON m.object_id = o.object_id
        WHERE o.type IN (''P'',''FN'',''IF'',''TF'',''V'',''TR'')
          AND o.is_ms_shipped = 0
          AND (
            m.definition LIKE ''%Data Source=%''
            OR m.definition LIKE ''%User ID=%''
            OR m.definition LIKE ''%Password=%''
            OR m.definition LIKE ''%pwd=%''
            OR m.definition LIKE ''%secret=%''
          );

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (
            ''' + @DbName + ''',
            CASE WHEN @Count = 0 THEN 3 WHEN @Count <= 2 THEN 2 WHEN @Count <= 5 THEN 1 ELSE 0 END,
            ISNULL(@ObjList, ''No non-compliant objects found'')
        );';
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
            DECLARE @ObjList NVARCHAR(MAX);
            SELECT @Count = COUNT(*),
                   @ObjList = STRING_AGG(QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + ''.'' + QUOTENAME(OBJECT_NAME(object_id)), '', '')
            FROM sys.sql_modules m
            JOIN sys.objects o ON m.object_id = o.object_id
            WHERE o.type IN (''P'',''FN'',''IF'',''TF'',''V'',''TR'')
              AND o.is_ms_shipped = 0
              AND (
                m.definition LIKE ''%Data Source=%''
                OR m.definition LIKE ''%User ID=%''
                OR m.definition LIKE ''%Password=%''
                OR m.definition LIKE ''%pwd=%''
                OR m.definition LIKE ''%secret=%''
              );

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (
                ''' + @DbName + ''',
                CASE WHEN @Count = 0 THEN 3 WHEN @Count <= 2 THEN 2 WHEN @Count <= 5 THEN 1 ELSE 0 END,
                ISNULL(@ObjList, ''No non-compliant objects found'')
            );';
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