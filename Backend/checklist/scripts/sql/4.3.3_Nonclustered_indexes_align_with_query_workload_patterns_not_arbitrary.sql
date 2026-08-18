-- Checklist: Nonclustered indexes align with query/workload patterns (not arbitrary)
-- Scope: DATABASE
-- Scoring: 3: >=90% of nonclustered indexes show active usage; 2: >=70%; 1: >=40%; 0: <40% or evaluation failure.

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
        DECLARE @TotalIdx INT;
        DECLARE @UsedIdx INT;
        DECLARE @UnusedIdx NVARCHAR(MAX);
        DECLARE @UsagePct FLOAT;

        SELECT @TotalIdx = COUNT(*),
               @UsedIdx = SUM(CASE WHEN (ISNULL(user_seeks,0) + ISNULL(user_scans,0) + ISNULL(user_lookups,0)) > 0 THEN 1 ELSE 0 END)
        FROM sys.indexes i
        JOIN sys.tables t ON i.object_id = t.object_id
        LEFT JOIN sys.dm_db_index_usage_stats us ON i.object_id = us.object_id AND i.index_id = us.index_id AND us.database_id = DB_ID()
        WHERE i.type = 2;

        SET @UsagePct = CASE WHEN @TotalIdx = 0 THEN 100.0 ELSE CAST(@UsedIdx AS FLOAT) / @TotalIdx * 100.0 END;

        SELECT @UnusedIdx = STRING_AGG(s.name + ''.'' + t.name + ''.'' + i.name, '', '')
        FROM sys.indexes i
        JOIN sys.tables t ON i.object_id = t.object_id
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        LEFT JOIN sys.dm_db_index_usage_stats us ON i.object_id = us.object_id AND i.index_id = us.index_id AND us.database_id = DB_ID()
        WHERE i.type = 2
          AND (ISNULL(user_seeks,0) + ISNULL(user_scans,0) + ISNULL(user_lookups,0)) = 0;

        DECLARE @DbScore INT;
        IF @UsagePct >= 90.0 SET @DbScore = 3;
        ELSE IF @UsagePct >= 70.0 SET @DbScore = 2;
        ELSE IF @UsagePct >= 40.0 SET @DbScore = 1;
        ELSE SET @DbScore = 0;

        DECLARE @DbFinding NVARCHAR(MAX);
        IF @UnusedIdx IS NULL OR @UnusedIdx = ''
            SET @DbFinding = CAST(@UsedIdx AS NVARCHAR) + '' of '' + CAST(@TotalIdx AS NVARCHAR) + '' nonclustered indexes show active usage ('' + CAST(@UsagePct AS NVARCHAR(5)) + ''%). No unused indexes found.'';
        ELSE
            SET @DbFinding = CAST(@UsedIdx AS NVARCHAR) + '' of '' + CAST(@TotalIdx AS NVARCHAR) + '' nonclustered indexes show active usage ('' + CAST(@UsagePct AS NVARCHAR(5)) + ''%). Unused: '' + @UnusedIdx;

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@pDbName, @DbScore, @DbFinding);
        ';

        EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(128)', @pDbName = @DbName;
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

SET @Result = CASE WHEN @