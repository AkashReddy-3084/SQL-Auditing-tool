-- Checklist: Unit tests exist for critical transformation logic (e.g., tSQLt)
-- Scope: DATABASE
-- Scoring: 3: tSQLt framework installed AND >=2 test procedures found. 2: tSQLt installed AND 1 test, OR no framework AND >=2 tests. 1: tSQLt installed AND 0 tests, OR no framework AND 1 test. 0: No framework and 0 tests.

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
    BEGIN TRY
        DECLARE @HasFramework BIT = 0;
        DECLARE @TestCount INT = 0;
        DECLARE @TestList NVARCHAR(MAX) = N'';

        SELECT @HasFramework = CASE WHEN SCHEMA_ID(N'tSQLt') IS NOT NULL THEN 1 ELSE 0 END;

        SELECT @TestCount = COUNT(*),
               @TestList = STRING_AGG(QUOTENAME(SCHEMA_NAME(schema_id)) + N'.' + QUOTENAME(name), N', ')
        FROM sys.procedures
        WHERE name LIKE N'test_%' OR name LIKE N'%_test';

        DECLARE @DbScore INT;
        IF @HasFramework = 1 AND @TestCount >= 2 SET @DbScore = 3;
        ELSE IF @HasFramework = 1 AND @TestCount = 1 SET @DbScore = 2;
        ELSE IF @HasFramework = 1 AND @TestCount = 0 SET @DbScore = 1;
        ELSE IF @HasFramework = 0 AND @TestCount >= 2 SET @DbScore = 2;
        ELSE IF @HasFramework = 0 AND @TestCount = 1 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

        DECLARE @DbFinding NVARCHAR(MAX) = N'tSQLt framework: ' + CASE WHEN @HasFramework = 1 THEN N'Installed' ELSE N'Not found' END + N'; Tests: ' + CAST(@TestCount AS NVARCHAR) + N' (' + ISNULL(@TestList, N'None') + N')';

        INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @DbScore, @DbFinding);
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, 0, 'Evaluation failed: ' + ERROR_MESSAGE());
    END CATCH;
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
            DECLARE @HasFramework BIT = 0;
            DECLARE @TestCount INT = 0;
            DECLARE @TestList NVARCHAR(MAX) = N'''';

            SELECT @HasFramework = CASE WHEN SCHEMA_ID(N''tSQLt'') IS NOT NULL THEN 1 ELSE 0 END;

            SELECT @TestCount = COUNT(*),
                   @TestList = STRING_AGG(QUOTENAME(SCHEMA_NAME(schema_id)) + N''.'' + QUOTENAME(name), N'''','')
            FROM sys.procedures
            WHERE name LIKE N''test_%'' OR name LIKE N''%_test'';

            DECLARE @DbScore INT;
            IF @HasFramework = 1 AND @TestCount >= 2 SET @DbScore = 3;
            ELSE IF @HasFramework = 1 AND @TestCount = 1 SET @DbScore = 2;
            ELSE IF @HasFramework = 1 AND @TestCount = 0 SET @DbScore = 1;
            ELSE IF @HasFramework = 0 AND @TestCount >= 2 SET @DbScore = 2;
            ELSE IF @HasFramework = 0 AND @TestCount = 1 SET @DbScore = 1;
            ELSE SET @DbScore = 0;

            DECLARE @DbFinding NVARCHAR(MAX) = N''tSQLt framework: '' + CASE WHEN @HasFramework = 1 THEN N''Installed'' ELSE N''Not found'' END + N''; Tests: '' + CAST(@TestCount AS NVARCHAR) + N'' ('' + ISNULL(@TestList, N''None'') + N'')'';

            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + @DbName + ''', @DbScore, @DbFinding);';
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, 0, 'Database evaluation failed');
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = (SELECT STRING_AGG(DbName, ', ') FROM #DbResults);

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);

SET @Finding = ISNULL(
    (SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''),
    'No non-compliant findings found'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,