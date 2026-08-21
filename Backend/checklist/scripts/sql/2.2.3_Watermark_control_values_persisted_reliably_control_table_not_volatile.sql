-- Checklist: Watermark/control values persisted reliably (control table, not volatile)
-- Scope: DATABASE
-- Scoring: 3: Persistent control tables found and referenced by ETL objects. 2: Persistent control tables found but ETL references unclear. 1: Only volatile mechanisms detected. 0: No control tables or watermark mechanisms found.

SET NOCOUNT ON;

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
    -- Azure SQL Database: Evaluate current database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @Cnt INT = 0;
    DECLARE @RefCnt INT = 0;
    DECLARE @DbScore INT = 0;
    DECLARE @Finding NVARCHAR(MAX) = ''No persistent control tables found'';

    SELECT @Cnt = COUNT(*) 
    FROM sys.tables t
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE t.type = ''U''
      AND (LOWER(t.name) LIKE ''%control%'' OR LOWER(t.name) LIKE ''%watermark%'' OR LOWER(t.name) LIKE ''%checkpoint%'');

    IF @Cnt > 0
    BEGIN
        SELECT @RefCnt = COUNT(*) 
        FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE t.type = ''U''
          AND (LOWER(t.name) LIKE ''%control%'' OR LOWER(t.name) LIKE ''%watermark%'' OR LOWER(t.name) LIKE ''%checkpoint%'')
          AND EXISTS (
              SELECT 1 FROM sys.sql_modules m
              JOIN sys.procedures p ON m.object_id = p.object_id
              WHERE m.definition LIKE ''%'' + QUOTENAME(s.name) + ''.'' + QUOTENAME(t.name) + ''%''
                 OR m.definition LIKE ''%'' + QUOTENAME(t.name) + ''%''
          );

        SELECT TOP 100 @Finding = STRING_AGG(s.name + ''.'' + t.name, '', '')
        FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        WHERE t.type = ''U''
          AND (LOWER(t.name) LIKE ''%control%'' OR LOWER(t.name) LIKE ''%watermark%'' OR LOWER(t.name) LIKE ''%checkpoint%'');
    END

    IF @Cnt > 0 AND @RefCnt > 0 SET @DbScore = 3;
    ELSE IF @Cnt > 0 SET @DbScore = 2;
    ELSE IF EXISTS (SELECT 1 FROM sys.sql_modules WHERE definition LIKE ''%#%watermark%'' OR definition LIKE ''%@watermark%'') SET @DbScore = 1;
    ELSE SET @DbScore = 0;

    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + @DbName + ''', @DbScore, @Finding);
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: Iterate user databases
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
            DECLARE @Cnt INT = 0;
            DECLARE @RefCnt INT = 0;
            DECLARE @DbScore INT = 0;
            DECLARE @Finding NVARCHAR(MAX) = ''No persistent control tables found'';

            SELECT @Cnt = COUNT(*) 
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE t.type = ''U''
              AND (LOWER(t.name) LIKE ''%control%'' OR LOWER(t.name) LIKE ''%watermark%'' OR LOWER(t.name) LIKE ''%checkpoint%'');

            IF @Cnt > 0
            BEGIN
                SELECT @RefCnt = COUNT(*) 
                FROM sys.tables t
                JOIN sys.schemas s ON t.schema_id = s.schema_id
                WHERE t.type = ''U''
                  AND (LOWER(t.name) LIKE ''%control%'' OR LOWER(t.name) LIKE ''%watermark%'' OR LOWER(t.name) LIKE ''%checkpoint%'')
                  AND EXISTS (
                      SELECT 1 FROM sys.sql_modules m
                      JOIN sys.procedures p ON m.object_id = p.object_id
                      WHERE m.definition LIKE ''%'' + QUOTENAME(s.name) + ''.'' + QUOTENAME(t.name) + ''%''
                         OR m.definition LIKE ''%'' + QUOTENAME(t.name) + ''%''
                  );

                SELECT TOP 100 @Finding = STRING_AGG(s.name + ''.'' + t.name, '', '')
                FROM sys.tables t
                JOIN sys.schemas s ON t.schema_id = s.schema_id
                WHERE t.type = ''U''
                  AND (LOWER(t.name) LIKE ''%control%'' OR LOWER(t.name) LIKE ''%watermark%'' OR LOWER(t.name) LIKE ''%checkpoint%'');
            END

            IF @Cnt > 0 AND @RefCnt > 0 SET @DbScore = 3;
            ELSE IF @Cnt > 0 SET @DbScore = 2;
            ELSE IF EXISTS (SELECT 1 FROM sys.sql_modules WHERE definition LIKE ''%#%watermark%'' OR definition LIKE ''%@watermark%'') SET @DbScore = 1;
            ELSE SET @DbScore = 0;

            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + @DbName + ''', @DbScore, @Finding);
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

SET @DatabaseQueried = ISNULL(
    (SELECT STRING_AGG(DbName, ', ') FROM #DbResults),
    'None'
);

SET @Score = ISNULL(
    (SELECT MIN(DbScore) FROM #DbResults),
    0
);

SET @Finding = ISNULL(
    (
        SELECT STRING_AGG(DbName + ': ' + Finding, '; ')
        FROM #DbResults
        WHERE Finding IS NOT NULL AND Finding <> ''
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