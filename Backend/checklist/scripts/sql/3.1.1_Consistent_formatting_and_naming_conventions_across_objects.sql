-- Checklist: Consistent formatting and naming conventions across objects
-- Scope: DATABASE
-- Scoring: 3: 0% violations, 2: <=5%, 1: 5-15%, 0: >15%

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

DECLARE @EvalSql NVARCHAR(MAX) = N'
    DECLARE @TotalObjects INT = 0;
    DECLARE @ViolationCount INT = 0;
    DECLARE @ViolatingObjects NVARCHAR(MAX) = '';
    DECLARE @ViolationPct FLOAT = 0;
    DECLARE @DbScore INT = 0;
    DECLARE @DbFinding NVARCHAR(MAX) = '';

    SELECT @TotalObjects = COUNT(*)
    FROM sys.objects
    WHERE type IN (''U'', ''V'', ''P'', ''FN'', ''IF'', ''TF'')
      AND is_ms_shipped = 0;

    SELECT @ViolationCount = COUNT(*),
           @ViolatingObjects = STRING_AGG(name, ''', ''')
    FROM sys.objects
    WHERE type IN (''U'', ''V'', ''P'', ''FN'', ''IF'', ''TF'')
      AND is_ms_shipped = 0
      AND (
          name LIKE ''% %''
          OR name LIKE ''%[^a-zA-Z0-9_]%%''
          OR (name <> LOWER(name) AND name <> UPPER(name))
      );

    SET @ViolationPct = CASE WHEN @TotalObjects > 0 THEN (@ViolationCount * 100.0) / @TotalObjects ELSE 0 END;

    IF @ViolationPct = 0 SET @DbScore = 3;
    ELSE IF @ViolationPct <= 5.0 SET @DbScore = 2;
    ELSE IF @ViolationPct <= 15.0 SET @DbScore = 1;
    ELSE SET @DbScore = 0;

    SET @DbFinding = CASE
        WHEN @DbScore = 3 THEN ''No naming convention violations found.''
        ELSE CAST(@ViolationCount AS NVARCHAR) + '' objects violate conventions ('' + CAST(ROUND(@ViolationPct, 1) AS NVARCHAR) + ''%%): '' + ISNULL(@ViolatingObjects, ''None'')
    END;

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (@pDbName, @DbScore, @DbFinding);
';

IF @IsAzureSQLDB = 1
BEGIN
    EXEC sp_executesql @EvalSql, N'@pDbName NVARCHAR(128)', @pDbName = DB_NAME();
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
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N'; ' + @EvalSql;
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