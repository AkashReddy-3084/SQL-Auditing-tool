-- Checklist: No manual production changes — all via pipeline
-- Scope: DATABASE
-- Scoring: 3=No recent changes; 2=Changes correlated with jobs (proxy); 1=Few changes, no job correlation; 0=Many changes, no job correlation
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @HasMsdb BIT = CASE WHEN @EngineEdition = 5 THEN 0 ELSE 1 END;

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

-- Get recent job runs if msdb is available (SQL Server / Azure SQL MI)
DECLARE @JobRuns INT = 0;
IF @HasMsdb = 1
BEGIN
    SELECT @JobRuns = COUNT(*)
    FROM msdb.dbo.sysjobhistory h
    JOIN msdb.dbo.sysjobs j ON h.job_id = j.job_id
    WHERE h.run_date >= CONVERT(INT, CONVERT(VARCHAR(8), GETDATE() - 7, 112))
      AND h.step_id = 0;
END

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
        DECLARE @ModCount INT;
        DECLARE @ModObjects NVARCHAR(MAX);
        SELECT @ModCount = COUNT(*),
               @ModObjects = STRING_AGG(SCHEMA_NAME(schema_id) + ''.'' + name, '', '')
        FROM sys.objects
        WHERE type IN (''U'',''P'',''V'',''FN'',''IF'',''TF'',''TR'',''PC'')
          AND is_ms_shipped = 0
          AND modify_date > DATEADD(day, -7, GETDATE());

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        SELECT ''' + @DbName + ''',
               CASE
                   WHEN @ModCount = 0 THEN 3
                   WHEN @ModCount > 0 AND ' + CAST(@JobRuns AS NVARCHAR) + ' > 0 THEN 2
                   WHEN @ModCount <= 5 THEN 1
                   ELSE 0
               END,
               CASE
                   WHEN @ModCount = 0 THEN ''No recent object modifications found.''
                   ELSE '''' + CAST(@ModCount AS NVARCHAR) + '' objects modified in last 7 days: '' + ISNULL(@ModObjects, ''None'')
               END;
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