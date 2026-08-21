-- Checklist: Ownership documented — not tribal knowledge
-- Scope: DATABASE
-- Scoring: 0: <10% objects documented; 1: 10-49%; 2: 50-89%; 3: >=90% objects have explicit ownership metadata via extended properties.

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
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
    DECLARE @TotalObjects INT;
    DECLARE @DocumentedObjects INT;
    DECLARE @UndocumentedList NVARCHAR(MAX);
    DECLARE @Pct DECIMAL(5,2);
    DECLARE @DbScore INT;
    DECLARE @DbFinding NVARCHAR(MAX);

    SELECT @TotalObjects = COUNT(*) FROM sys.objects WHERE type IN (''U'',''P'',''V'',''FN'',''IF'',''TF'') AND is_ms_shipped = 0;
    SELECT @DocumentedObjects = COUNT(DISTINCT ep.major_id)
    FROM sys.extended_properties ep
    JOIN sys.objects o ON ep.major_id = o.object_id
    WHERE o.type IN (''U'',''P'',''V'',''FN'',''IF'',''TF'') AND o.is_ms_shipped = 0
    AND ep.name IN (''Owner'', ''Author'', ''Maintainer'', ''Steward'', ''Contact'');

    SET @Pct = CASE WHEN @TotalObjects = 0 THEN 100.0 ELSE (@DocumentedObjects * 100.0) / @TotalObjects END;

    SET @DbScore = CASE
        WHEN @Pct >= 90 THEN 3
        WHEN @Pct >= 50 THEN 2
        WHEN @Pct >= 10 THEN 1
        ELSE 0
    END;

    SELECT @UndocumentedList = STRING_AGG(QUOTENAME(SCHEMA_NAME(o.schema_id)) + ''.'' + QUOTENAME(o.name), '', '')
    FROM sys.objects o
    WHERE o.type IN (''U'',''P'',''V'',''FN'',''IF'',''TF'') AND o.is_ms_shipped = 0
    AND NOT EXISTS (
        SELECT 1 FROM sys.extended_properties ep
        WHERE ep.major_id = o.object_id
        AND ep.name IN (''Owner'', ''Author'', ''Maintainer'', ''Steward'', ''Contact'')
    );

    SET @DbFinding = ''Coverage: '' + CAST(@Pct AS NVARCHAR(10)) + ''% ('' + CAST(@DocumentedObjects AS NVARCHAR(10)) + ''/' + CAST(@TotalObjects AS NVARCHAR(10)) + ''). '' +
        CASE WHEN @UndocumentedList IS NOT NULL THEN ''Undocumented: '' + @UndocumentedList ELSE ''All objects documented.'' END;

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (' + QUOTENAME(@DbName, '''') + N', @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: Iterate user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @TotalObjects INT;
            DECLARE @DocumentedObjects INT;
            DECLARE @UndocumentedList NVARCHAR(MAX);
            DECLARE @Pct DECIMAL(5,2);
            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);

            SELECT @TotalObjects = COUNT(*) FROM sys.objects WHERE type IN (''U'',''P'',''V'',''FN'',''IF'',''TF'') AND is_ms_shipped = 0;
            SELECT @DocumentedObjects = COUNT(DISTINCT ep.major_id)
            FROM sys.extended_properties ep
            JOIN sys.objects o ON ep.major_id = o.object_id
            WHERE o.type IN (''U'',''P'',''V'',''FN'',''IF'',''TF'') AND o.is_ms_shipped = 0
            AND ep.name IN (''Owner'', ''Author'', ''Maintainer'', ''Steward'', ''Contact'');

            SET @Pct = CASE WHEN @TotalObjects = 0 THEN 100.0 ELSE (@DocumentedObjects * 100.0) / @TotalObjects END;

            SET @DbScore = CASE
                WHEN @Pct >= 90 THEN 3
                WHEN @Pct >= 50 THEN 2
                WHEN @Pct >= 10 THEN 1
                ELSE 0
            END;

            SELECT @UndocumentedList = STRING_AGG(QUOTENAME(SCHEMA_NAME(o.schema_id)) + ''.'' + QUOTENAME(o.name), '', '')
            FROM sys.objects o
            WHERE o.type IN (''U'',''P'',''V'',''FN'',''IF'',''TF'') AND o.is_ms_shipped = 0
            AND NOT EXISTS (
                SELECT 1 FROM sys.extended_properties ep
                WHERE ep.major_id = o.object_id
                AND ep.name IN (''Owner'', ''Author'', ''Maintainer'', ''Steward'', ''Contact'')
            );

            SET @DbFinding = ''Coverage: '' + CAST(@Pct AS NVARCHAR(10)) + ''% ('' + CAST(@DocumentedObjects AS NVARCHAR(10)) + ''/' + CAST(@TotalObjects AS NVARCHAR(10)) + ''). '' +
                CASE WHEN @UndocumentedList IS NOT NULL THEN ''Undocumented: '' + @UndocumentedList ELSE ''All objects documented.'' END;

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (' + QUOTENAME(@DbName, '''') + N', @DbScore, @DbFinding);
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
    SELECT STRING_AGG(DbName, ', ') FROM #DbResults
);

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);

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