-- Checklist: ETL has structured error handling (TRY...CATCH, event handlers, failure paths)
-- Scope: DATABASE
-- Scoring: 3: 100% of user modules contain TRY...CATCH. 2: >=80% contain TRY...CATCH. 1: >=50% contain TRY...CATCH. 0: <50% contain TRY...CATCH.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @SafeDbName NVARCHAR(256);
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
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    SET @SafeDbName = REPLACE(@DbName, '''', '''''');
    SET @Sql = N'
    DECLARE @Total INT = 0;
    DECLARE @WithTryCatch INT = 0;
    DECLARE @MissingObjects NVARCHAR(MAX) = '';

    SELECT @Total = COUNT(*)
    FROM sys.objects o
    JOIN sys.sql_modules m ON o.object_id = m.object_id
    WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''TR'')
      AND o.is_ms_shipped = 0
      AND m.definition IS NOT NULL;

    SELECT @WithTryCatch = COUNT(*)
    FROM sys.objects o
    JOIN sys.sql_modules m ON o.object_id = m.object_id
    WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''TR'')
      AND o.is_ms_shipped = 0
      AND m.definition IS NOT NULL
      AND m.definition LIKE ''%TRY%''
      AND m.definition LIKE ''%CATCH%'';

    SELECT @MissingObjects = STRING_AGG(s.name + ''.'' + o.name, '', '')
    FROM sys.objects o
    JOIN sys.schemas s ON o.schema_id = s.schema_id
    LEFT JOIN sys.sql_modules m ON o.object_id = m.object_id
    WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''TR'')
      AND o.is_ms_shipped = 0
      AND m.definition IS NOT NULL
      AND (m.definition NOT LIKE ''%TRY%'' OR m.definition NOT LIKE ''%CATCH%'');

    DECLARE @Pct FLOAT = CASE WHEN @Total > 0 THEN CAST(@WithTryCatch AS FLOAT) / @Total * 100 ELSE 100 END;
    DECLARE @DbScore INT = CASE
        WHEN @Total = 0 THEN 3
        WHEN @Pct >= 100 THEN 3
        WHEN @Pct >= 80 THEN 2
        WHEN @Pct >= 50 THEN 1
        ELSE 0
    END;

    DECLARE @DbFinding NVARCHAR(MAX) = CASE
        WHEN @Total = 0 THEN ''No user modules found.''
        WHEN @DbScore = 3 THEN ''All '' + CAST(@Total AS NVARCHAR) + '' modules contain TRY...CATCH.''
        ELSE '''' + CAST(@WithTryCatch AS NVARCHAR) + '' of '' + CAST(@Total AS NVARCHAR) + '' modules contain TRY...CATCH. Missing: '' + ISNULL(@MissingObjects, ''None'')
    END;

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (''' + @SafeDbName + ''', @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
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
            SET @SafeDbName = REPLACE(@DbName, '''', '''''');
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @Total INT = 0;
            DECLARE @WithTryCatch INT = 0;
            DECLARE @MissingObjects NVARCHAR(MAX) = '';

            SELECT @Total = COUNT(*)
            FROM sys.objects o
            JOIN sys.sql_modules m ON o.object_id = m.object_id
            WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''TR'')
              AND o.is_ms_shipped = 0
              AND m.definition IS NOT NULL;

            SELECT @WithTryCatch = COUNT(*)
            FROM sys.objects o
            JOIN sys.sql_modules m ON o.object_id = m.object_id
            WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''TR'')
              AND o.is_ms_shipped = 0
              AND m.definition IS NOT NULL
              AND m.definition LIKE ''%TRY%''
              AND m.definition LIKE ''%CATCH%'';

            SELECT @MissingObjects = STRING_AGG(s.name + ''.'' + o.name, '', '')
            FROM sys.objects o
            JOIN sys.schemas s ON o.schema_id = s.schema_id
            LEFT JOIN sys.sql_modules m ON o.object_id = m.object_id
            WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''TR'')
              AND o.is_ms_shipped = 0
              AND m.definition IS NOT NULL
              AND (m.definition NOT LIKE ''%TRY%'' OR m.definition NOT LIKE ''%CATCH%'');

            DECLARE @Pct FLOAT = CASE WHEN @Total > 0 THEN CAST(@WithTryCatch AS FLOAT) / @Total * 100 ELSE 100 END;
            DECLARE @DbScore INT = CASE
                WHEN @Total = 0 THEN 3
                WHEN @Pct >= 100 THEN 3
                WHEN @Pct >= 80 THEN 2
                WHEN @Pct >= 50 THEN 1
                ELSE 0
            END;

            DECLARE @DbFinding NVARCHAR(MAX) = CASE
                WHEN @Total = 0 THEN ''No user modules found.''
                WHEN @DbScore = 3 THEN ''All '' + CAST(@Total AS NVARCHAR) + '' modules contain TRY...CATCH.''
                ELSE '''' + CAST(@WithTryCatch AS NVARCHAR) + '' of '' + CAST(@Total AS NVARCHAR) + '' modules contain TRY...CATCH. Missing: '' + ISNULL(@MissingObjects, ''None'')
            END;

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + @SafeDbName + ''', @DbScore, @DbFinding);
            ';

            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, 'Database evaluation failed: ' + ERROR_MESSAGE());
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''), 'No non-compliant findings found');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;