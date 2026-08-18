-- Checklist: Code is self-documenting or well-commented for complex logic
-- Scope: DATABASE
-- Scoring: 0: 0% documented. 1: 1-24%. 2: 25-79%. 3: >=80%. (Proxy check; full compliance requires human review.)
-- NOTE: This script provides automated evidence. Full compliance requires human review.

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
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @Total INT, @Documented INT, @Undocumented NVARCHAR(MAX);
    SELECT @Total = COUNT(*) FROM sys.objects WHERE type IN (''P'', ''FN'', ''IF'', ''TF'', ''V'', ''TR'') AND is_ms_shipped = 0;
    SELECT @Documented = COUNT(DISTINCT o.object_id)
    FROM sys.objects o
    LEFT JOIN sys.sql_modules sm ON o.object_id = sm.object_id
    LEFT JOIN sys.extended_properties ep ON o.object_id = ep.major_id AND ep.minor_id = 0 AND ep.name = ''MS_Description''
    WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''V'', ''TR'') AND o.is_ms_shipped = 0
      AND ((sm.definition IS NOT NULL AND (sm.definition LIKE ''%--%'' OR sm.definition LIKE ''%/*%'')) OR ep.value IS NOT NULL);
    SELECT @Undocumented = STRING_AGG(QUOTENAME(SCHEMA_NAME(o.schema_id)) + ''.'' + QUOTENAME(o.name), '', '')
    FROM sys.objects o
    LEFT JOIN sys.sql_modules sm ON o.object_id = sm.object_id
    LEFT JOIN sys.extended_properties ep ON o.object_id = ep.major_id AND ep.minor_id = 0 AND ep.name = ''MS_Description''
    WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''V'', ''TR'') AND o.is_ms_shipped = 0
      AND ((sm.definition IS NULL OR (sm.definition NOT LIKE ''%--%'' AND sm.definition NOT LIKE ''%/*%'')) AND ep.value IS NULL);
    DECLARE @Pct FLOAT = CAST(@Documented AS FLOAT) / NULLIF(@Total, 0) * 100;
    DECLARE @DbScore INT;
    DECLARE @DbFinding NVARCHAR(MAX);
    IF @Total = 0 SET @DbScore = 3;
    ELSE IF @Pct >= 80 SET @DbScore = 3;
    ELSE IF @Pct >= 25 SET @DbScore = 2;
    ELSE IF @Pct >= 1 SET @DbScore = 1;
    ELSE SET @DbScore = 0;
    SET @DbFinding = CAST(@Documented AS NVARCHAR) + '' of '' + CAST(@Total AS NVARCHAR) + '' objects ('' + CAST(ROUND(@Pct, 0) AS NVARCHAR) + ''%) have comments or extended properties.'';
    IF @DbScore < 2 AND @Undocumented IS NOT NULL SET @DbFinding = @DbFinding + '' Undocumented: '' + @Undocumented;
    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql;
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
            DECLARE @Total INT, @Documented INT, @Undocumented NVARCHAR(MAX);
            SELECT @Total = COUNT(*) FROM sys.objects WHERE type IN (''P'', ''FN'', ''IF'', ''TF'', ''V'', ''TR'') AND is_ms_shipped = 0;
            SELECT @Documented = COUNT(DISTINCT o.object_id)
            FROM sys.objects o
            LEFT JOIN sys.sql_modules sm ON o.object_id = sm.object_id
            LEFT JOIN sys.extended_properties ep ON o.object_id = ep.major_id AND ep.minor_id = 0 AND ep.name = ''MS_Description''
            WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''V'', ''TR'') AND o.is_ms_shipped = 0
              AND ((sm.definition IS NOT NULL AND (sm.definition LIKE ''%--%'' OR sm.definition LIKE ''%/*%'')) OR ep.value IS NOT NULL);
            SELECT @Undocumented = STRING_AGG(QUOTENAME(SCHEMA_NAME(o.schema_id)) + ''.'' + QUOTENAME(o.name), '', '')
            FROM sys.objects o
            LEFT JOIN sys.sql_modules sm ON o.object_id = sm.object_id
            LEFT JOIN sys.extended_properties ep ON o.object_id = ep.major_id AND ep.minor_id = 0 AND ep.name = ''MS_Description''
            WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'', ''V'', ''TR'') AND o.is_ms_shipped = 0
              AND ((sm.definition IS NULL OR (sm.definition NOT LIKE ''%--%'' AND sm.definition NOT LIKE ''%/*%'')) AND ep.value IS NULL);
            DECLARE @Pct FLOAT = CAST(@Documented AS FLOAT) / NULLIF(@Total, 0) * 100;
            DECLARE @DbScore INT;
            DECLARE @DbFinding NVARCHAR(MAX);
            IF @Total = 0 SET @DbScore = 3;
            ELSE IF @Pct >= 80 SET @DbScore = 3;
            ELSE IF @Pct >= 25 SET @DbScore = 2;
            ELSE IF @Pct >= 1 SET @DbScore = 1;
            ELSE SET @DbScore = 0;
            SET @DbFinding = CAST(@Documented AS NVARCHAR) + '' of '' + CAST(@Total AS NVARCHAR) + '' objects ('' + CAST(ROUND(@Pct, 0) AS NVARCHAR) + ''%) have comments or extended properties.'';
            IF @DbScore < 2 AND @Undocumented IS NOT NULL SET @DbFinding = @DbFinding + '' Undocumented: '' + @Undocumented;
            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @DbFinding);
            ';
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES (@DbName, 0, 'Database evaluation failed');
        END CATCH;
        FETCH NEXT FROM db_cursor INTO @DbName;
    END
    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = (SELECT STRING_AGG(DbName, ', ') FROM #DbResults);
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''), 'No non-compliant findings found');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;