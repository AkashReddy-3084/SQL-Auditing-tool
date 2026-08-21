-- Checklist: Fill factor and index options set deliberately where needed
-- Scope: DATABASE
-- Scoring: 0: 0% explicit; 1: 1-24%; 2: 25-74%; 3: 75-100%
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @TotalIndexes INT;
    DECLARE @ExplicitIndexes INT;
    DECLARE @Pct DECIMAL(5,2);
    DECLARE @DbScore INT;
    DECLARE @DbFinding NVARCHAR(MAX);

    SELECT 
        @TotalIndexes = COUNT(*),
        @ExplicitIndexes = SUM(CASE WHEN fill_factor BETWEEN 1 AND 99 OR pad_index = 1 OR ignore_dup_key = 1 THEN 1 ELSE 0 END)
    FROM sys.indexes
    WHERE object_id > 0;

    SET @Pct = CASE WHEN @TotalIndexes = 0 THEN 0 ELSE (@ExplicitIndexes * 100.0) / @TotalIndexes END;

    SET @DbScore = CASE 
        WHEN @Pct >= 75 THEN 3
        WHEN @Pct >= 25 THEN 2
        WHEN @Pct > 0 THEN 1
        ELSE 0
    END;

    SET @DbFinding = ''Total indexes: '' + CAST(@TotalIndexes AS NVARCHAR(10)) + ''. Explicitly configured: '' + CAST(@ExplicitIndexes AS NVARCHAR(10)) + '' ('' + CAST(@Pct AS NVARCHAR(10)) + ''%).'';

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (@pDbName, @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(128)', @pDbName = @DbName;
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
            DECLARE @TotalIndexes INT;
            DECLARE @ExplicitIndexes INT;
            DECLARE @Pct DECIMAL(5,2);
            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            SELECT 
                @TotalIndexes = COUNT(*),
                @ExplicitIndexes = SUM(CASE WHEN fill_factor BETWEEN 1 AND 99 OR pad_index = 1 OR ignore_dup_key = 1 THEN 1 ELSE 0 END)
            FROM sys.indexes
            WHERE object_id > 0;

            SET @Pct = CASE WHEN @TotalIndexes = 0 THEN 0 ELSE (@ExplicitIndexes * 100.0) / @TotalIndexes END;

            SET @DbScore = CASE 
                WHEN @Pct >= 75 THEN 3
                WHEN @Pct >= 25 THEN 2
                WHEN @Pct > 0 THEN 1
                ELSE 0
            END;

            SET @DbFinding = ''Total indexes: '' + CAST(@TotalIndexes AS NVARCHAR(10)) + ''. Explicitly configured: '' + CAST(@ExplicitIndexes AS NVARCHAR(10)) + '' ('' + CAST(@Pct AS NVARCHAR(10)) + ''%).'';

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@pDbName, @DbScore, @DbFinding);
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
        WHERE Finding IS NOT NULL
          AND Finding <> ''
    ),
    'No non-compliant findings found'
);

SET @Result