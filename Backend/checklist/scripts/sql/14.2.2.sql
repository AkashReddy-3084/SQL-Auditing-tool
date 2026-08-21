/*
    Checklist Item : 14.2.2 - Missing indexes reviewed and applied judiciously
    Scope          : SERVER (server-scoped DMVs, attributed per database)
    Access         : READ ONLY - SELECT against system DMVs only; writes go to temp tables.
*/
SET NOCOUNT ON;

DECLARE @EngineEdition   INT            = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @CurrentDbOnly   BIT            = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) IN (5, 9, 11) THEN 1 ELSE 0 END;
DECLARE @Result          NVARCHAR(50)   = N'Fail';
DECLARE @Score           INT            = 1;
DECLARE @DatabaseQueried NVARCHAR(1000) = N'';
DECLARE @Finding         NVARCHAR(4000) = N'';
DECLARE @TopList         NVARCHAR(2000) = N'';
DECLARE @UptimeDays      INT            = NULL;
DECLARE @TotalMissing    INT            = 0;
DECLARE @HighImpact      INT            = 0;
DECLARE @UnusedIndexes   INT            = 0;

BEGIN TRY
    SELECT @UptimeDays = DATEDIFF(DAY, si.sqlserver_start_time, GETDATE())
    FROM sys.dm_os_sys_info AS si;
END TRY
BEGIN CATCH
    SET @UptimeDays = NULL;
END CATCH;

IF OBJECT_ID('tempdb..#MissingIndexes') IS NOT NULL DROP TABLE #MissingIndexes;
CREATE TABLE #MissingIndexes
(
    DatabaseName       SYSNAME        NOT NULL,
    TableStatement     NVARCHAR(4000) NULL,
    ImprovementMeasure FLOAT          NOT NULL,
    AvgUserImpact      FLOAT          NOT NULL
);

IF OBJECT_ID('tempdb..#UnusedIndexes') IS NOT NULL DROP TABLE #UnusedIndexes;
CREATE TABLE #UnusedIndexes
(
    DatabaseName SYSNAME NOT NULL,
    UnusedCount  INT     NOT NULL
);

BEGIN TRY
    IF @CurrentDbOnly = 1
    BEGIN
        INSERT INTO #MissingIndexes (DatabaseName, TableStatement, ImprovementMeasure, AvgUserImpact)
        SELECT DB_NAME(),
               d.[statement],
               gs.avg_total_user_cost * gs.avg_user_impact * (gs.user_seeks + gs.user_scans) / 100.0,
               gs.avg_user_impact
        FROM sys.dm_db_missing_index_group_stats AS gs
        INNER JOIN sys.dm_db_missing_index_groups AS g
                ON g.index_group_handle = gs.group_handle
        INNER JOIN sys.dm_db_missing_index_details AS d
                ON d.index_handle = g.index_handle
        WHERE d.database_id = DB_ID();

        INSERT INTO #UnusedIndexes (DatabaseName, UnusedCount)
        SELECT DB_NAME(), COUNT(*)
        FROM sys.dm_db_index_usage_stats AS us
        WHERE us.database_id = DB_ID()
          AND us.index_id > 1
          AND (us.user_seeks + us.user_scans + us.user_lookups) = 0
          AND us.user_updates >= 1000
        HAVING COUNT(*) > 0;
    END
    ELSE
    BEGIN
        INSERT INTO #MissingIndexes (DatabaseName, TableStatement, ImprovementMeasure, AvgUserImpact)
        SELECT DB_NAME(d.database_id),
               d.[statement],
               gs.avg_total_user_cost * gs.avg_user_impact * (gs.user_seeks + gs.user_scans) / 100.0,
               gs.avg_user_impact
        FROM sys.dm_db_missing_index_group_stats AS gs
        INNER JOIN sys.dm_db_missing_index_groups AS g
                ON g.index_group_handle = gs.group_handle
        INNER JOIN sys.dm_db_missing_index_details AS d
                ON d.index_handle = g.index_handle
        WHERE d.database_id > 4
          AND DB_NAME(d.database_id) IS NOT NULL;

        INSERT INTO #UnusedIndexes (DatabaseName, UnusedCount)
        SELECT DB_NAME(us.database_id), COUNT(*)
        FROM sys.dm_db_index_usage_stats AS us
        WHERE us.database_id > 4
          AND DB_NAME(us.database_id) IS NOT NULL
          AND us.index_id > 1
          AND (us.user_seeks + us.user_scans + us.user_lookups) = 0
          AND us.user_updates >= 1000
        GROUP BY DB_NAME(us.database_id);
    END
END TRY
BEGIN CATCH
    SET @Finding = N'Partial data: ' + ERROR_MESSAGE() + N' ';
END CATCH;

SELECT @TotalMissing = COUNT(*),
       @HighImpact   = ISNULL(SUM(CASE WHEN mi.ImprovementMeasure >= 100000 THEN 1 ELSE 0 END), 0)
FROM #MissingIndexes AS mi;

SELECT @UnusedIndexes = ISNULL(SUM(ui.UnusedCount), 0)
FROM #UnusedIndexes AS ui;

SELECT @TopList = @TopList
                + CASE WHEN @TopList = N'' THEN N'' ELSE N' | ' END
                + t.DatabaseName + N' -> ' + ISNULL(LEFT(t.TableStatement, 120), N'(unknown object)')
                + N' [improvement ' + LTRIM(STR(t.ImprovementMeasure, 18, 0))
                + N', avg impact ' + LTRIM(STR(t.AvgUserImpact, 6, 1)) + N'%]'
FROM (SELECT TOP (3) mi.DatabaseName, mi.TableStatement, mi.ImprovementMeasure, mi.AvgUserImpact
      FROM #MissingIndexes AS mi
      ORDER BY mi.ImprovementMeasure DESC) AS t;

SELECT @DatabaseQueried = @DatabaseQueried
                        + CASE WHEN @DatabaseQueried = N'' THEN N'' ELSE N', ' END
                        + x.DatabaseName
FROM (SELECT DatabaseName FROM #MissingIndexes
      UNION
      SELECT DatabaseName FROM #UnusedIndexes) AS x;

IF @DatabaseQueried = N''
    SET @DatabaseQueried = CASE WHEN @CurrentDbOnly = 1 THEN DB_NAME() ELSE N'All user databases' END;

IF @HighImpact = 0 AND @UnusedIndexes = 0
    SET @Score = 3;
ELSE IF @HighImpact <= 5 AND @UnusedIndexes <= 10
    SET @Score = 2;
ELSE
    SET @Score = 1;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding = ISNULL(@Finding, N'')
    + N'Missing-index DMV review across '
    + CASE WHEN @CurrentDbOnly = 1 THEN N'the current database' ELSE N'all user databases' END
    + N': ' + CAST(@TotalMissing AS NVARCHAR(20)) + N' outstanding recommendation(s), of which '
    + CAST(@HighImpact AS NVARCHAR(20)) + N' are high impact (improvement measure >= 100000). '
    + CAST(@UnusedIndexes AS NVARCHAR(20))
    + N' nonclustered index(es) are never read yet carry >= 1000 maintenance updates, indicating indexes applied without review. '
    + CASE WHEN @TopList = N''
           THEN N'No missing-index recommendations are currently recorded. '
           ELSE N'Top recommendations: ' + @TopList + N'. ' END
    + N'DMV statistics cover '
    + ISNULL(CAST(@UptimeDays AS NVARCHAR(20)), N'an unknown number of')
    + N' day(s) since the last engine restart'
    + CASE WHEN @UptimeDays IS NOT NULL AND @UptimeDays < 7
           THEN N' (short sampling window - findings may be incomplete).'
           ELSE N'.' END;

IF OBJECT_ID('tempdb..#MissingIndexes') IS NOT NULL DROP TABLE #MissingIndexes;
IF OBJECT_ID('tempdb..#UnusedIndexes') IS NOT NULL DROP TABLE #UnusedIndexes;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;