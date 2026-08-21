-- Checklist: Late-arriving / out-of-order data handled without corruption
-- Scope: DATABASE
-- Scoring: 0=No evidence, 1=One indicator, 2=Two indicators, 3=Three indicators. NOTE: This script provides automated evidence. Full compliance requires human review.

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
    -- Azure SQL Database: evaluate current DB only
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @StagingCount INT = 0;
    DECLARE @SCD2Count INT = 0;
    DECLARE @MergeProcCount INT = 0;
    DECLARE @IndicatorCount INT = 0;
    DECLARE @DbScore INT = 0;
    DECLARE @Finding NVARCHAR(MAX) = ''No evidence of late/out-of-order data handling mechanisms found.'';

    SELECT @StagingCount = COUNT(*) FROM sys.tables t
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE t.is_ms_shipped = 0
      AND (s.name LIKE ''%stg%'' OR s.name LIKE ''%landing%'' OR s.name LIKE ''%raw%'' OR s.name LIKE ''%stage%'');

    SELECT @SCD2Count = COUNT(DISTINCT t.object_id) FROM sys.tables t
    JOIN sys.columns c ON t.object_id = c.object_id
    WHERE t.is_ms_shipped = 0
      AND c.name IN (''effective_start_date'', ''valid_from'', ''start_date'', ''effective_date'', ''effective_end_date'', ''valid_to'', ''end_date'', ''expiration_date'', ''is_current'', ''current_flag'');

    SELECT @MergeProcCount = COUNT(*) FROM sys.procedures p
    WHERE p.is_ms_shipped = 0
      AND OBJECT_DEFINITION(p.object_id) LIKE ''%MERGE%'';

    SET @IndicatorCount = (CASE WHEN @StagingCount > 0 THEN 1 ELSE 0 END) +
                          (CASE WHEN @SCD2Count > 0 THEN 1 ELSE 0 END) +
                          (CASE WHEN @MergeProcCount > 0 THEN 1 ELSE 0 END);

    SET @DbScore = CASE WHEN @IndicatorCount >= 3 THEN 3 WHEN @IndicatorCount = 2 THEN 2 WHEN @IndicatorCount = 1 THEN 1 ELSE 0 END;
    SET @DbScore = CASE WHEN @DbScore > 2 THEN 2 ELSE @DbScore END;

    SET @Finding = ''Staging tables: '' + CAST(@StagingCount AS NVARCHAR(10)) + ''; SCD2 patterns: '' + CAST(@SCD2Count AS NVARCHAR(10)) + ''; MERGE procedures: '' + CAST(@MergeProcCount AS NVARCHAR(10)) + ''.'';

    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + QUOTENAME(@DbName, '''') + ''', @DbScore, @Finding);
    ';
    EXEC sp_executesql @Sql;
    SET @DatabaseQueried = @DbName;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
            DECLARE @StagingCount INT = 0;
            DECLARE @SCD2Count INT = 0;
            DECLARE @MergeProcCount INT = 0;
            DECLARE @IndicatorCount INT = 0;
            DECLARE @DbScore INT = 0;
            DECLARE @Finding NVARCHAR(MAX) = ''No evidence of late/out-of-order data handling mechanisms found.'';

            SELECT @StagingCount = COUNT(*) FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE t.is_ms_shipped = 0
              AND (s.name LIKE ''%stg%'' OR s.name LIKE ''%landing%'' OR s.name LIKE ''%raw%'' OR s.name LIKE ''%stage%'');

            SELECT @SCD2Count = COUNT(DISTINCT t.object_id) FROM sys.tables t
            JOIN sys.columns c ON t.object_id = c.object_id
            WHERE t.is_ms_shipped = 0
              AND c.name IN (''effective_start_date'', ''valid_from'', ''start_date'', ''effective_date'', ''effective_end_date'', ''valid_to'', ''end_date'', ''expiration_date'', ''is_current'', ''current_flag'');

            SELECT @MergeProcCount = COUNT(*) FROM sys.procedures p
            WHERE p.is_ms_shipped = 0
              AND OBJECT_DEFINITION(p.object_id) LIKE ''%MERGE%'';

            SET @IndicatorCount = (CASE WHEN @StagingCount > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN @SCD2Count > 0 THEN 1 ELSE 0 END) +
                                  (CASE WHEN @MergeProcCount > 0 THEN 1 ELSE 0 END);

            SET @DbScore = CASE WHEN @IndicatorCount >= 3 THEN 3 WHEN @IndicatorCount = 2 THEN 2 WHEN @IndicatorCount = 1 THEN 1 ELSE 0 END;
            SET @DbScore = CASE WHEN @DbScore > 2 THEN 2 ELSE @DbScore END;

            SET @Finding = ''Staging tables: '' + CAST(@StagingCount AS NVARCHAR(10)) + ''; SCD2 patterns: '' + CAST(@SCD2Count AS NVARCHAR(10)) + ''; MERGE procedures: '' + CAST(@MergeProcCount AS NVARCHAR(10)) + ''.'';

            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + QUOTENAME(@DbName, '''') + ''', @DbScore, @Finding);
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

    SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');
END

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);

SET @Finding = ISNULL(
    (SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''),
    'No non-compliant findings found'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;