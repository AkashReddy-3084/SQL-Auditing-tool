-- Checklist: Storage growth monitored; autogrowth settings sane (fixed size, not tiny %)
-- Scope: DATABASE
-- Scoring: 3=All files use fixed-size growth >= 8MB (data) / 4MB (logs); 2=All fixed-size but some < threshold; 1=Some files use percentage-based growth; 0=Majority use percentage growth or autogrowth disabled.

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
    SET @Sql = N'
    DECLARE @PctCount INT = 0;
    DECLARE @SmallDataCount INT = 0;
    DECLARE @SmallLogCount INT = 0;
    DECLARE @BadFiles NVARCHAR(MAX) = '''';

    SELECT
        @PctCount = COUNT(CASE WHEN is_percent_growth = 1 THEN 1 END),
        @SmallDataCount = COUNT(CASE WHEN type = 0 AND growth < 1024 THEN 1 END),
        @SmallLogCount = COUNT(CASE WHEN type = 1 AND growth < 512 THEN 1 END),
        @BadFiles = STRING_AGG(
            CASE
                WHEN is_percent_growth = 1 THEN name + '' (PctGrowth)''
                WHEN type = 0 AND growth < 1024 THEN name + '' ('' + CAST(growth AS NVARCHAR) + '' pages)''
                WHEN type = 1 AND growth < 512 THEN name + '' ('' + CAST(growth AS NVARCHAR) + '' pages)''
            END, '' | '')
    FROM sys.database_files
    WHERE type IN (0, 1);

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        DB_NAME(),
        CASE
            WHEN @PctCount > 0 THEN 1
            WHEN @SmallDataCount > 0 OR @SmallLogCount > 0 THEN 2
            ELSE 3
        END,
        ISNULL(NULLIF(@BadFiles, ''''), ''No non-compliant objects found'')
    );';
    EXEC sp_executesql @Sql;
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
            DECLARE @PctCount INT = 0;
            DECLARE @SmallDataCount INT = 0;
            DECLARE @SmallLogCount INT = 0;
            DECLARE @BadFiles NVARCHAR(MAX) = '''';

            SELECT
                @PctCount = COUNT(CASE WHEN is_percent_growth = 1 THEN 1 END),
                @SmallDataCount = COUNT(CASE WHEN type = 0 AND growth < 1024 THEN 1 END),
                @SmallLogCount = COUNT(CASE WHEN type = 1 AND growth < 512 THEN 1 END),
                @BadFiles = STRING_AGG(
                    CASE
                        WHEN is_percent_growth = 1 THEN name + '' (PctGrowth)''
                        WHEN type = 0 AND growth < 1024 THEN name + '' ('' + CAST(growth AS NVARCHAR) + '' pages)''
                        WHEN type = 1 AND growth < 512 THEN name + '' ('' + CAST(growth AS NVARCHAR) + '' pages)''
                    END, '' | '')
            FROM sys.database_files
            WHERE type IN (0, 1);

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (
                DB_NAME(),
                CASE
                    WHEN @PctCount > 0 THEN 1
                    WHEN @SmallDataCount > 0 OR @SmallLogCount > 0 THEN 2
                    ELSE 3
                END,
                ISNULL(NULLIF(@BadFiles, ''''), ''No non-compliant objects found'')
            );';
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
        WHERE Finding <> 'No non-compliant objects found'
    ),
    'All databases comply with sane autogrowth settings'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;