-- Checklist: Extended properties / documentation on key objects
-- Scope: DATABASE
-- Scoring: 0: 0% documented, 1: 1-24% documented, 2: 25-74% documented, 3: 75-100% documented

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @IsAzureSQLDB BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

IF @IsAzureSQLDB = 1
BEGIN
    SET @DbName = DB_NAME();
    DECLARE @Total INT, @Doc INT, @Pct DECIMAL(5,2);

    SELECT @Total = COUNT(*) FROM (
        SELECT object_id FROM sys.tables WHERE is_ms_shipped = 0
        UNION ALL
        SELECT object_id FROM sys.views WHERE is_ms_shipped = 0
        UNION ALL
        SELECT object_id FROM sys.procedures WHERE is_ms_shipped = 0
    ) t;

    SELECT @Doc = COUNT(DISTINCT major_id)
    FROM sys.extended_properties
    WHERE class = 1
      AND major_id IN (
        SELECT object_id FROM sys.tables WHERE is_ms_shipped = 0
        UNION ALL
        SELECT object_id FROM sys.views WHERE is_ms_shipped = 0
        UNION ALL
        SELECT object_id FROM sys.procedures WHERE is_ms_shipped = 0
      );

    SET @Pct = CASE WHEN @Total = 0 THEN 100.0 ELSE (@Doc * 100.0) / @Total END;
    SET @Score = CASE WHEN @Pct >= 75 THEN 3 WHEN @Pct >= 25 THEN 2 WHEN @Pct >= 1 THEN 1 ELSE 0 END;
    SET @Finding = CAST(@Total AS NVARCHAR) + ' total key objects, ' + CAST(@Doc AS NVARCHAR) + ' documented (' + CAST(@Pct AS NVARCHAR) + '%).';
    SET @DatabaseQueried = @DbName;
END
ELSE
BEGIN
    CREATE TABLE #DbResults (
        DbName NVARCHAR(128),
        DbScore INT,
        Finding NVARCHAR(MAX)
    );

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
            DECLARE @Total INT, @Doc INT, @Pct DECIMAL(5,2);
            SELECT @Total = COUNT(*) FROM (
                SELECT object_id FROM sys.tables WHERE is_ms_shipped = 0
                UNION ALL
                SELECT object_id FROM sys.views WHERE is_ms_shipped = 0
                UNION ALL
                SELECT object_id FROM sys.procedures WHERE is_ms_shipped = 0
            ) t;

            SELECT @Doc = COUNT(DISTINCT major_id)
            FROM sys.extended_properties
            WHERE class = 1
              AND major_id IN (
                SELECT object_id FROM sys.tables WHERE is_ms_shipped = 0
                UNION ALL
                SELECT object_id FROM sys.views WHERE is_ms_shipped = 0
                UNION ALL
                SELECT object_id FROM sys.procedures WHERE is_ms_shipped = 0
              );

            SET @Pct = CASE WHEN @Total = 0 THEN 100.0 ELSE (@Doc * 100.0) / @Total END;

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (
                ''' + REPLACE(@DbName, '''', '''''') + ''',
                CASE WHEN @Pct >= 75 THEN 3 WHEN @Pct >= 25 THEN 2 WHEN @Pct >= 1 THEN 1 ELSE 0 END,
                CAST(@Total AS NVARCHAR) + '' total key objects, '' + CAST(@Doc AS NVARCHAR) + '' documented ('' + CAST(@Pct AS NVARCHAR) + ''%).''
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

    SET @DatabaseQueried = ISNULL(
        (SELECT STRING_AGG(DbName, ', ') FROM #DbResults),
        'No user databases found'
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

    DROP TABLE #DbResults;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;