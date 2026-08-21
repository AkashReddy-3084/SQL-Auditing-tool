-- Checklist: Database schema and code source-controlled (SSDT/SQL project or migration scripts)
-- Scope: DATABASE
-- Scoring: 0: No proxy evidence found. 1: Minimal/ambiguous references. 2: Clear proxy evidence found (requires human review). 3: Not achievable automatically.

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
    DECLARE @Count INT = 0;
    SELECT @Count = COUNT(*) FROM sys.extended_properties WHERE value LIKE ''%git%'' OR value LIKE ''%svn%'' OR value LIKE ''%tfvc%'' OR value LIKE ''%source control%'' OR value LIKE ''%migration%'';
    IF @Count = 0
    BEGIN
        SELECT @Count = COUNT(*) FROM sys.sql_modules WHERE definition LIKE ''%git%'' OR definition LIKE ''%svn%'' OR definition LIKE ''%tfvc%'' OR definition LIKE ''%source control%'' OR definition LIKE ''%migration%'';
    END;
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (''' + @DbName + ''', CASE WHEN @Count > 0 THEN 2 ELSE 0 END, CASE WHEN @Count > 0 THEN ''Found '' + CAST(@Count AS NVARCHAR) + '' objects with source control/migration references'' ELSE ''No source control proxy evidence found'' END);
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
            DECLARE @Count INT = 0;
            SELECT @Count = COUNT(*) FROM sys.extended_properties WHERE value LIKE ''%git%'' OR value LIKE ''%svn%'' OR value LIKE ''%tfvc%'' OR value LIKE ''%source control%'' OR value LIKE ''%migration%'';
            IF @Count = 0
            BEGIN
                SELECT @Count = COUNT(*) FROM sys.sql_modules WHERE definition LIKE ''%git%'' OR definition LIKE ''%svn%'' OR definition LIKE ''%tfvc%'' OR definition LIKE ''%source control%'' OR definition LIKE ''%migration%'';
            END;
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + @DbName + ''', CASE WHEN @Count > 0 THEN 2 ELSE 0 END, CASE WHEN @Count > 0 THEN ''Found '' + CAST(@Count AS NVARCHAR) + '' objects with source control/migration references'' ELSE ''No source control proxy evidence found'' END);
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

SET @Finding = ISNULL(
    (SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''),
    'No non-compliant findings found'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

-- NOTE: This script provides automated evidence. Full compliance requires human review.

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;