-- Checklist: Transformation logic documented and reproducible
-- Scope: DATABASE
-- Scoring: 0: <20% documented/reproducible or none found; 1: 20-49%; 2: 50-89%; 3: >=90% documented/reproducible. NOTE: This script provides automated evidence. Full compliance requires human review.

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
        DECLARE @Total INT = 0;
        DECLARE @Both INT = 0;
        DECLARE @Pct INT = 0;

        SELECT @Total = COUNT(*)
        FROM sys.objects o
        WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'')
          AND o.is_ms_shipped = 0;

        SELECT @Both = COUNT(*)
        FROM sys.objects o
        JOIN sys.extended_properties ep ON o.object_id = ep.major_id AND ep.minor_id = 0
        JOIN sys.sql_modules sm ON o.object_id = sm.object_id
        WHERE o.type IN (''P'', ''FN'', ''IF'', ''TF'')
          AND o.is_ms_shipped = 0
          AND (ep.name LIKE ''%Description%'' OR ep.name LIKE ''%Documentation%'' OR ep.name LIKE ''%Comment%'')
          AND sm.definition IS NOT NULL
          AND LEN(sm.definition) > 100;

        IF @Total > 0
            SET @Pct = CAST(@Both AS FLOAT) / @Total * 100;

        DECLARE @DbScore INT = 0;
        IF @Total = 0 SET @DbScore = 0;
        ELSE IF @Pct < 20 SET @DbScore = 0;
        ELSE IF @Pct < 50 SET @DbScore = 1;
        ELSE IF @Pct < 90 SET @DbScore = 2;
        ELSE SET @DbScore = 3;

        DECLARE @DbFinding NVARCHAR(MAX) = ''Total transformation objects: '' + CAST(@Total AS NVARCHAR(10)) + ''; Documented & Reproducible: '' + CAST(@Both AS NVARCHAR(10)) + '' ('' + CAST(@Pct AS NVARCHAR(5)) + ''%)''.

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore, @DbFinding);
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