-- Checklist: Integration tests validate end-to-end ETL
-- Scope: DATABASE
-- Scoring: 0=No evidence, 1=Minimal test artifacts, 2=Multiple test artifacts/properties, 3=Dedicated test framework/schema detected
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @ObjCount INT = 0;
DECLARE @PropCount INT = 0;
DECLARE @SchemaCount INT = 0;
DECLARE @ObjList NVARCHAR(MAX) = '';

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
        SELECT @ObjCount = COUNT(*) FROM sys.objects WHERE type IN (''P'',''U'') AND (name LIKE ''%test%'' OR name LIKE ''%integration%'' OR name LIKE ''%e2e%'');
        SELECT @PropCount = COUNT(*) FROM sys.extended_properties WHERE name LIKE ''%test%'' OR value LIKE ''%integration%'' OR value LIKE ''%etl%'';
        SELECT @SchemaCount = COUNT(*) FROM sys.schemas WHERE name LIKE ''%test%'' OR name LIKE ''%integration%'';
        SELECT @ObjList = STRING_AGG(s.name + ''.'' + o.name, '', '') FROM sys.objects o JOIN sys.schemas s ON o.schema_id = s.schema_id WHERE o.type IN (''P'',''U'') AND (o.name LIKE ''%test%'' OR o.name LIKE ''%integration%'' OR o.name LIKE ''%e2e%'');
    ';
    EXEC sp_executesql @Sql, N'@ObjCount INT OUTPUT, @PropCount INT OUTPUT, @SchemaCount INT OUTPUT, @ObjList NVARCHAR(MAX) OUTPUT',
        @ObjCount OUTPUT, @PropCount OUTPUT, @SchemaCount OUTPUT, @ObjList OUTPUT;

    IF @SchemaCount > 0 SET @Score = 3;
    ELSE IF @ObjCount >= 3 OR @PropCount > 0 SET @Score = 2;
    ELSE IF @ObjCount >= 1 SET @Score = 1;
    ELSE SET @Score = 0;

    SET @Finding = CASE WHEN @ObjList <> '' THEN @ObjList ELSE 'No test artifacts found' END;
    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @Score, @Finding);
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @ObjCount = 0; SET @PropCount = 0; SET @SchemaCount = 0; SET @ObjList = '';
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
                SELECT @ObjCount = COUNT(*) FROM sys.objects WHERE type IN (''P'',''U'') AND (name LIKE ''%test%'' OR name LIKE ''%integration%'' OR name LIKE ''%e2e%'');
                SELECT @PropCount = COUNT(*) FROM sys.extended_properties WHERE name LIKE ''%test%'' OR value LIKE ''%integration%'' OR value LIKE ''%etl%'';
                SELECT @SchemaCount = COUNT(*) FROM sys.schemas WHERE name LIKE ''%test%'' OR name LIKE ''%integration%'';
                SELECT @ObjList = STRING_AGG(s.name + ''.'' + o.name, '', '') FROM sys.objects o JOIN sys.schemas s ON o.schema_id = s.schema_id WHERE o.type IN (''P'',''U'') AND (o.name LIKE ''%test%'' OR o.name LIKE ''%integration%'' OR o.name LIKE ''%e2e%'');
            ';
            EXEC sp_executesql @Sql, N'@ObjCount INT OUTPUT, @PropCount INT OUTPUT, @SchemaCount INT OUTPUT, @ObjList NVARCHAR(MAX) OUTPUT',
                @ObjCount OUTPUT, @PropCount OUTPUT, @SchemaCount OUTPUT, @ObjList OUTPUT;

            IF @SchemaCount > 0 SET @Score = 3;
            ELSE IF @ObjCount >= 3 OR @PropCount > 0 SET @Score = 2;
            ELSE IF @ObjCount >= 1 SET @Score = 1;
            ELSE SET @Score = 0;

            SET @Finding = CASE WHEN @ObjList <> '' THEN @ObjList ELSE 'No test artifacts found' END;
        END TRY
        BEGIN CATCH
            SET @Score = 0;
            SET @Finding = 'Database evaluation failed';
        END CATCH;

        INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @Score, @Finding);
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