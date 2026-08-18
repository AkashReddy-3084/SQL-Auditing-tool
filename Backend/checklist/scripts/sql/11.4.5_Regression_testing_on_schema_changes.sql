-- Checklist: Regression testing on schema changes
-- Scope: DATABASE
-- Scoring: 0: No test-related metadata found. 1: Minimal evidence (1-2 test artifacts). 2: Moderate evidence (3-5 test artifacts). 3: Strong evidence (>5 test artifacts or dedicated test schemas/properties).
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: evaluate current connected database only
    DECLARE @PropCount INT = 0;
    DECLARE @SchemaCount INT = 0;
    DECLARE @TotalCount INT = 0;
    DECLARE @Artifacts NVARCHAR(MAX) = '';

    SELECT @PropCount = COUNT(*) 
    FROM sys.extended_properties 
    WHERE name LIKE '%test%' OR name LIKE '%regression%' OR name LIKE '%coverage%';

    SELECT @SchemaCount = COUNT(*) 
    FROM sys.schemas 
    WHERE name LIKE '%test%' OR name LIKE '%qa%' OR name LIKE '%automation%';

    SET @TotalCount = @PropCount + @SchemaCount;

    SELECT @Artifacts = STRING_AGG(name + ' on ' + ISNULL(OBJECT_NAME(major_id), 'schema/column'), ', ')
    FROM sys.extended_properties
    WHERE name LIKE '%test%' OR name LIKE '%regression%' OR name LIKE '%coverage%';

    IF @SchemaCount > 0
    BEGIN
        DECLARE @SchemaList NVARCHAR(MAX) = '';
        SELECT @SchemaList = STRING_AGG(name, ', ') 
        FROM sys.schemas 
        WHERE name LIKE '%test%' OR name LIKE '%qa%' OR name LIKE '%automation%';
        SET @Artifacts = ISNULL(@Artifacts + '; ', '') + 'Test schemas: ' + @SchemaList;
    END

    IF @Artifacts IS NULL OR @Artifacts = '' SET @Artifacts = 'No test-related metadata found';

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        DB_NAME(),
        CASE
            WHEN @TotalCount = 0 THEN 0
            WHEN @TotalCount <= 2 THEN 1
            WHEN @TotalCount <= 5 THEN 2
            ELSE 3
        END,
        'Found ' + CAST(@TotalCount AS NVARCHAR(10)) + ' test-related artifacts: ' + @Artifacts
    );
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate online user databases
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
            DECLARE @PropCount INT = 0;
            DECLARE @SchemaCount INT = 0;
            DECLARE @TotalCount INT = 0;
            DECLARE @Artifacts NVARCHAR(MAX) = '';

            SELECT @PropCount = COUNT(*) 
            FROM sys.extended_properties 
            WHERE name LIKE ''%test%'' OR name LIKE ''%regression%'' OR name LIKE ''%coverage%'';

            SELECT @SchemaCount = COUNT(*) 
            FROM sys.schemas 
            WHERE name LIKE ''%test%'' OR name LIKE ''%qa%'' OR name LIKE ''%automation%'';

            SET @TotalCount = @PropCount + @SchemaCount;

            SELECT @Artifacts = STRING_AGG(name + '' on '' + ISNULL(OBJECT_NAME(major_id), ''schema/column''), '', '')
            FROM sys.extended_properties
            WHERE name LIKE ''%test%'' OR name LIKE ''%regression%'' OR name LIKE ''%coverage%'';

            IF @SchemaCount > 0
            BEGIN
                DECLARE @SchemaList NVARCHAR(MAX) = '';
                SELECT @SchemaList = STRING_AGG(name, '', '') 
                FROM sys.schemas 
                WHERE name LIKE ''%test%'' OR name LIKE ''%qa%'' OR name LIKE ''%automation%'';
                SET @Artifacts = ISNULL(@Artifacts + ''; '', '') + ''Test schemas: '' + @SchemaList;
            END

            IF @Artifacts IS NULL OR @Artifacts = '' SET @Artifacts = ''No test-related metadata found'';

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (
                DB_NAME(),
                CASE
                    WHEN @TotalCount = 0 THEN 0
                    WHEN @TotalCount <= 2 THEN 1
                    WHEN @TotalCount <= 5 THEN 2
                    ELSE 3
                END,
                ''Found '' + CAST(@TotalCount AS NVARCHAR(10)) + '' test-related artifacts: '' + @Artifacts
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