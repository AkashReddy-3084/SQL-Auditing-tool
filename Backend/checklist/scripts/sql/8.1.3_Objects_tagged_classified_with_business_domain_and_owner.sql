-- Checklist: Objects tagged/classified with business domain and owner
-- Scope: DATABASE
-- Scoring: 0: <20% objects tagged; 1: 20-49% tagged; 2: 50-79% tagged; 3: >=80% tagged
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
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
    SET @DbName = DB_NAME();
    SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
    DECLARE @TotalObjects INT;
    DECLARE @TaggedObjects INT;
    DECLARE @Pct FLOAT;
    SELECT @TotalObjects = COUNT(*) FROM sys.objects WHERE type IN (''U'', ''V'', ''P'', ''FN'', ''IF'', ''TF'');
    SELECT @TaggedObjects = COUNT(DISTINCT major_id) FROM sys.extended_properties WHERE class = 1 AND (UPPER(name) LIKE ''%DOMAIN%'' OR UPPER(name) LIKE ''%OWNER%'' OR UPPER(name) LIKE ''%BUSINESS%'');
    IF OBJECT_ID(''sys.sensitivity_classifications'') IS NOT NULL
    BEGIN
        SELECT @TaggedObjects = COUNT(DISTINCT o.object_id) FROM sys.objects o JOIN sys.sensitivity_classifications sc ON o.object_id = sc.major_id WHERE o.type IN (''U'', ''V'', ''P'', ''FN'', ''IF'', ''TF'');
    END
    SET @Pct = CASE WHEN @TotalObjects = 0 THEN 100.0 ELSE (@TaggedObjects * 100.0) / @TotalObjects END;
    DECLARE @DbScore INT;
    SET @DbScore = CASE WHEN @Pct >= 80 THEN 3 WHEN @Pct >= 50 THEN 2 WHEN @Pct >= 20 THEN 1 ELSE 0 END;
    DECLARE @DbFinding NVARCHAR(MAX);
    SET @DbFinding = ''Total objects: '' + CAST(@TotalObjects AS NVARCHAR(10)) + '', Tagged: '' + CAST(@TaggedObjects AS NVARCHAR(10)) + '' ('' + CAST(@Pct AS NVARCHAR(5)) + ''%)'';
    INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES ('' + REPLACE(@DbName, '''', '''''') + '', @DbScore, @DbFinding);';
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
            DECLARE @TotalObjects INT;
            DECLARE @TaggedObjects INT;
            DECLARE @Pct FLOAT;
            SELECT @TotalObjects = COUNT(*) FROM sys.objects WHERE type IN (''U'', ''V'', ''P'', ''FN'', ''IF'', ''TF'');
            SELECT @TaggedObjects = COUNT(DISTINCT major_id) FROM sys.extended_properties WHERE class = 1 AND (UPPER(name) LIKE ''%DOMAIN%'' OR UPPER(name) LIKE ''%OWNER%'' OR UPPER(name) LIKE ''%BUSINESS%'');
            IF OBJECT_ID(''sys.sensitivity_classifications'') IS NOT NULL
            BEGIN
                SELECT @TaggedObjects = COUNT(DISTINCT o.object_id) FROM sys.objects o JOIN sys.sensitivity_classifications sc ON o.object_id = sc.major_id WHERE o.type IN (''U'', ''V'', ''P'', ''FN'', ''IF'', ''TF'');
            END
            SET @Pct = CASE WHEN @TotalObjects = 0 THEN 100.0 ELSE (@TaggedObjects * 100.0) / @TotalObjects END;
            DECLARE @DbScore INT;
            SET @DbScore = CASE WHEN @Pct >= 80 THEN 3 WHEN @Pct >= 50 THEN 2 WHEN @Pct >= 20 THEN 1 ELSE 0 END;
            DECLARE @DbFinding NVARCHAR(MAX);
            SET @DbFinding = ''Total objects: '' + CAST(@TotalObjects AS NVARCHAR(10)) + '', Tagged: '' + CAST(@TaggedObjects AS NVARCHAR(10)) + '' ('' + CAST(@Pct AS NVARCHAR(5)) + ''%)'';
            INSERT INTO #DbResults (DbName, DbScore, Finding) VALUES ('' + REPLACE(@DbName, '''', '''''') + '', @DbScore, @DbFinding);';
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

SET @DatabaseQueried = (SELECT STRING_AGG(DbName, ', ') FROM #DbResults);
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults WHERE Finding IS NOT NULL AND Finding <> ''), 'No non-compliant findings found');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;