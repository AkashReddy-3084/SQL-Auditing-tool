-- Checklist: Query hints used sparingly and documented where present
-- Scope: DATABASE
-- Scoring: 3: No hints found. 2: 1-3 hints found. 1: 4-10 hints found. 0: >10 hints found.
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
    -- Azure SQL Database: evaluate current DB only (no USE or cross-DB allowed)
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @HintCount INT = 0;
    DECLARE @HintModules NVARCHAR(MAX) = '''';

    SELECT @HintCount = COUNT(*),
           @HintModules = STRING_AGG(QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + ''.'' + QUOTENAME(name), '', '')
    FROM sys.sql_modules m
    JOIN sys.objects o ON m.object_id = o.object_id
    WHERE o.type IN (''P'',''V'',''FN'',''IF'',''TF'',''TR'')
      AND m.definition IS NOT NULL
      AND (
        m.definition LIKE ''%OPTION%''
        OR m.definition LIKE ''%NOLOCK%''
        OR m.definition LIKE ''%READPAST%''
        OR m.definition LIKE ''%READCOMMITTEDLOCK%''
        OR m.definition LIKE ''%UPDLOCK%''
        OR m.definition LIKE ''%XLOCK%''
        OR m.definition LIKE ''%TABLOCK%''
        OR m.definition LIKE ''%ROWLOCK%''
        OR m.definition LIKE ''%INDEX(%''
        OR m.definition LIKE ''%FORCESEEK%''
        OR m.definition LIKE ''%FORCESCAN%''
        OR m.definition LIKE ''%OPTIMIZE FOR%''
        OR m.definition LIKE ''%RECOMPILE%''
        OR m.definition LIKE ''%USE PLAN%''
        OR m.definition LIKE ''%KEEPFIXED PLAN%''
        OR m.definition LIKE ''%LOOP JOIN%''
        OR m.definition LIKE ''%MERGE JOIN%''
        OR m.definition LIKE ''%HASH JOIN%''
        OR m.definition LIKE ''%EXPAND VIEWS%''
        OR m.definition LIKE ''%FORCE ORDER%''
        OR m.definition LIKE ''%MAXDOP%''
      );

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        ''' + @DbName + N''',
        CASE
            WHEN @HintCount = 0 THEN 3
            WHEN @HintCount BETWEEN 1 AND 3 THEN 2
            WHEN @HintCount BETWEEN 4 AND 10 THEN 1
            ELSE 0
        END,
        CASE
            WHEN @HintCount = 0 THEN ''No query hints found''
            ELSE ''Found '' + CAST(@HintCount AS NVARCHAR(10)) + '' hint(s) in: '' + @HintModules
        END
    );
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @HintCount INT = 0;
            DECLARE @HintModules NVARCHAR(MAX) = '''';

            SELECT @HintCount = COUNT(*),
                   @HintModules = STRING_AGG(QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + ''.'' + QUOTENAME(name), '', '')
            FROM sys.sql_modules m
            JOIN sys.objects o ON m.object_id = o.object_id
            WHERE o.type IN (''P'',''V'',''FN'',''IF'',''TF'',''TR'')
              AND m.definition IS NOT NULL
              AND (
                m.definition LIKE ''%OPTION%''
                OR m.definition LIKE ''%NOLOCK%''
                OR m.definition LIKE ''%READPAST%''
                OR m.definition LIKE ''%READCOMMITTEDLOCK%''
                OR m.definition LIKE ''%UPDLOCK%''
                OR m.definition LIKE ''%XLOCK%''
                OR m.definition LIKE ''%TABLOCK%''
                OR m.definition LIKE ''%ROWLOCK%''
                OR m.definition LIKE ''%INDEX(%''
                OR m.definition LIKE ''%FORCESEEK%''
                OR m.definition LIKE ''%FORCESCAN%''
                OR m.definition LIKE ''%OPTIMIZE FOR%''
                OR m.definition LIKE ''%RECOMPILE%''
                OR m.definition LIKE ''%USE PLAN%''
                OR m.definition LIKE ''%KEEPFIXED PLAN%''
                OR m.definition LIKE ''%LOOP JOIN%''
                OR m.definition LIKE ''%MERGE JOIN%''
                OR m.definition LIKE ''%HASH JOIN%''
                OR m.definition LIKE ''%EXPAND VIEWS%''
                OR m.definition LIKE ''%FORCE ORDER%''
                OR m.definition LIKE ''%MAXDOP%''
              );

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (
                ''' + @DbName + N''',
                CASE
                    WHEN @HintCount = 0 THEN 3
                    WHEN @HintCount BETWEEN 1 AND 3 THEN 2
                    WHEN @HintCount BETWEEN 4 AND 10 THEN 1
                    ELSE 0
                END,
                CASE
                    WHEN @HintCount = 0 THEN ''No query hints found''
                    ELSE ''Found '' + CAST(@HintCount AS NVARCHAR(10)) + '' hint(s) in: '' + @HintModules
                END
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

SET @DatabaseQueried = (SELECT STRING_AGG(DbName, ', ') FROM #DbResults);
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''), 'No non-compliant findings found');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;