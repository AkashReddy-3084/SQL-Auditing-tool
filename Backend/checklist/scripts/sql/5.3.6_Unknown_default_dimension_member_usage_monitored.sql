-- Checklist: Unknown/default dimension member usage monitored
-- Scope: DATABASE
-- Scoring: 0: No monitoring artifacts found. 1: Only columns referencing unknown/default monitoring found. 2: Tables explicitly referencing unknown/default member monitoring found. 3: Dedicated monitoring tables and procedures for unknown/default usage are present.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;
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

IF @IsAzureSQLDB = 1
BEGIN
    SET @DbName = DB_NAME();
    
    DECLARE @Artifacts TABLE (Type NVARCHAR(10), Name NVARCHAR(256));
    INSERT INTO @Artifacts
    SELECT 'Table', t.name FROM sys.tables t WHERE t.name LIKE '%unknown%' OR t.name LIKE '%default%' OR t.name LIKE '%monitor%';
    INSERT INTO @Artifacts
    SELECT 'Column', t.name + '.' + c.name FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE c.name LIKE '%unknown%' OR c.name LIKE '%default%';
    INSERT INTO @Artifacts
    SELECT 'Procedure', p.name FROM sys.procedures p WHERE p.name LIKE '%unknown%' OR p.name LIKE '%default%' OR p.name LIKE '%monitor%';

    DECLARE @ArtifactList NVARCHAR(MAX) = (SELECT STRING_AGG(Type + ': ' + Name, ', ') FROM @Artifacts);
    DECLARE @DbScore INT = 0;
    DECLARE @Finding NVARCHAR(MAX) = ISNULL(@ArtifactList, 'No monitoring artifacts found');

    IF @ArtifactList IS NULL SET @DbScore = 0;
    ELSE BEGIN
        DECLARE @HasTable BIT = (SELECT COUNT(*) FROM @Artifacts WHERE Type = 'Table');
        DECLARE @HasProc BIT = (SELECT COUNT(*) FROM @Artifacts WHERE Type = 'Procedure');
        IF @HasTable > 0 AND @HasProc > 0 SET @DbScore = 3;
        ELSE IF @HasTable > 0 SET @DbScore = 2;
        ELSE SET @DbScore = 1;
    END

    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, @DbScore, @Finding);
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @Artifacts TABLE (Type NVARCHAR(10), Name NVARCHAR(256));
            INSERT INTO @Artifacts
            SELECT ''Table'', t.name FROM sys.tables t WHERE t.name LIKE ''%unknown%'' OR t.name LIKE ''%default%'' OR t.name LIKE ''%monitor%'';
            INSERT INTO @Artifacts
            SELECT ''Column'', t.name + ''.'' + c.name FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id WHERE c.name LIKE ''%unknown%'' OR c.name LIKE ''%default%'';
            INSERT INTO @Artifacts
            SELECT ''Procedure'', p.name FROM sys.procedures p WHERE p.name LIKE ''%unknown%'' OR p.name LIKE ''%default%'' OR p.name LIKE ''%monitor%'';

            DECLARE @ArtifactList NVARCHAR(MAX) = (SELECT STRING_AGG(Type + '': '' + Name, '', '') FROM @Artifacts);
            DECLARE @DbScore INT = 0;
            DECLARE @Finding NVARCHAR(MAX) = ISNULL(@ArtifactList, ''No monitoring artifacts found'');

            IF @ArtifactList IS NULL SET @DbScore = 0;
            ELSE BEGIN
                DECLARE @HasTable BIT = (SELECT COUNT(*) FROM @Artifacts WHERE Type = ''Table'');
                DECLARE @HasProc BIT = (SELECT COUNT(*) FROM @Artifacts WHERE Type = ''Procedure'');
                IF @HasTable > 0 AND @HasProc > 0 SET @DbScore = 3;
                ELSE IF @HasTable > 0 SET @DbScore = 2;
                ELSE SET @DbScore = 1;
            END

            SELECT @DbName AS DbName, @DbScore AS DbScore, @Finding AS Finding;
            ';
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            EXEC sp_executesql @Sql, N'@DbName NVARCHAR(256)', @DbName = @DbName;
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