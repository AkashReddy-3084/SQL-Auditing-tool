-- Checklist: Consistent formatting and naming conventions across objects
-- Scope: DATABASE
-- Scoring: 0=<30% consistency, 1=30-59%, 2=60-89%, 3=>=90% of objects follow naming/formatting rules. Worst-case score across all user databases determines final result.
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @ConsistencyPct DECIMAL(5,2);
        SELECT @ConsistencyPct = ISNULL(SUM(CASE
            WHEN o.name LIKE ''[a-zA-Z]%''
             AND o.name NOT LIKE ''% %''
             AND o.name NOT LIKE ''%[^a-zA-Z0-9_]%''
             AND (o.name = LOWER(o.name) OR o.name = UPPER(o.name))
             AND sm.definition LIKE ''%--%''
             AND sm.definition LIKE ''%[ ][ ][ ][ ]%''
            THEN 1 ELSE 0 END) * 100.0 / NULLIF(COUNT(*), 0), 0)
        FROM sys.objects o
        JOIN sys.sql_modules sm ON o.object_id = sm.object_id
        WHERE o.type IN (''U'', ''V'', ''P'', ''FN'', ''IF'', ''TF'', ''TR'')
          AND o.is_ms_shipped = 0
          AND sm.definition IS NOT NULL;

        INSERT INTO #DbResults (DbName, DbScore)
        VALUES (' + QUOTENAME(@DbName, '''') + N', CASE
            WHEN @ConsistencyPct >= 90 THEN 3
            WHEN @ConsistencyPct >= 60 THEN 2
            WHEN @ConsistencyPct >= 30 THEN 1
            ELSE 0
        END);';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Aggregate: worst-case score across all databases
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;