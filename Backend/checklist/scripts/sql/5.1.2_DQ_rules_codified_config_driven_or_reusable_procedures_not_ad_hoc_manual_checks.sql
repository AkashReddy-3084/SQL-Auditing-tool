-- Checklist: DQ rules codified (config-driven or reusable procedures), not ad-hoc manual checks
-- Scope: DATABASE
-- Scoring: 0: No DQ-related objects found. 1: 1-2 objects found. 2: 3-5 objects found. 3: 6+ objects found.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

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
    DECLARE @ObjCount INT;
    DECLARE @ObjList NVARCHAR(MAX);
    SELECT @ObjCount = COUNT(*),
           @ObjList = STRING_AGG(SCHEMA_NAME(schema_id) + '.' + name, ', ') WITHIN GROUP (ORDER BY name)
    FROM sys.objects
    WHERE type IN ('U', 'P')
      AND is_ms_shipped = 0
      AND (name LIKE '%DQ%' OR name LIKE '%DataQuality%' OR name LIKE '%Validation%' OR name LIKE '%Rule%');

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (DB_NAME(),
            CASE WHEN @ObjCount = 0 THEN 0
                 WHEN @ObjCount <= 2 THEN 1
                 WHEN @ObjCount <= 5 THEN 2
                 ELSE 3 END,
            ISNULL(@ObjList, 'No DQ-related objects found'));
END
ELSE
BEGIN
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
            DECLARE @ObjCount INT;
            DECLARE @ObjList NVARCHAR(MAX);
            SELECT @ObjCount = COUNT(*),
                   @ObjList = STRING_AGG(SCHEMA_NAME(schema_id) + ''.'' + name, '', '') WITHIN GROUP (ORDER BY name)
            FROM sys.objects
            WHERE type IN (''U'', ''P'')
              AND is_ms_shipped = 0
              AND (name LIKE ''%DQ%'' OR name LIKE ''%DataQuality%'' OR name LIKE ''%Validation%'' OR name LIKE ''%Rule%'');

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@pDbName,
                    CASE WHEN @ObjCount = 0 THEN 0
                         WHEN @ObjCount <= 2 THEN 1
                         WHEN @ObjCount <= 5 THEN 2
                         ELSE 3 END,
                    ISNULL(@ObjList, ''No DQ-related objects found''));
            ';
            EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(128)', @pDbName = @DbName;
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