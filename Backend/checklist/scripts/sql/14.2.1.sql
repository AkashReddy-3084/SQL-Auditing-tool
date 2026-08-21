SET NOCOUNT ON;

-- 14.2.1 - Index usage analyzed (seeks vs scans) against workload
-- Read-only. Measures seek/scan balance and never-used nonclustered indexes across user databases.

DECLARE @IsAzureSqlDb bit = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @StatsWindowDays int = NULL;

BEGIN TRY
    SELECT @StatsWindowDays = DATEDIFF(day, sqlserver_start_time, SYSDATETIME())
    FROM sys.dm_os_sys_info;
END TRY
BEGIN CATCH
    SET @StatsWindowDays = NULL;
END CATCH;

IF OBJECT_ID('tempdb..#IndexUsage') IS NOT NULL
    DROP TABLE #IndexUsage;

CREATE TABLE #IndexUsage
(
    DatabaseName        sysname      NOT NULL,
    TotalIndexes        int          NOT NULL,
    NonClusteredIndexes int          NOT NULL,
    UsedIndexes         int          NOT NULL,
    UnusedNonClustered  int          NOT NULL,
    TotalSeeks          bigint       NOT NULL,
    TotalScans          bigint       NOT NULL,
    TotalLookups        bigint       NOT NULL,
    TotalUpdates        bigint       NOT NULL
);

DECLARE @SkippedDbs nvarchar(max) = N'';

IF @IsAzureSqlDb = 1
BEGIN
    BEGIN TRY
        INSERT INTO #IndexUsage
        (
            DatabaseName, TotalIndexes, NonClusteredIndexes, UsedIndexes, UnusedNonClustered,
            TotalSeeks, TotalScans, TotalLookups, TotalUpdates
        )
        SELECT
            DB_NAME(),
            COUNT(*),
            ISNULL(SUM(CASE WHEN i.type_desc = 'NONCLUSTERED' THEN 1 ELSE 0 END), 0),
            ISNULL(SUM(CASE WHEN ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0) > 0 THEN 1 ELSE 0 END), 0),
            ISNULL(SUM(CASE WHEN i.type_desc = 'NONCLUSTERED'
                             AND ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0) = 0
                            THEN 1 ELSE 0 END), 0),
            ISNULL(SUM(CONVERT(bigint, ISNULL(us.user_seeks, 0))), 0),
            ISNULL(SUM(CONVERT(bigint, ISNULL(us.user_scans, 0))), 0),
            ISNULL(SUM(CONVERT(bigint, ISNULL(us.user_lookups, 0))), 0),
            ISNULL(SUM(CONVERT(bigint, ISNULL(us.user_updates, 0))), 0)
        FROM sys.indexes AS i
        INNER JOIN sys.objects AS o
            ON o.object_id = i.object_id
        LEFT JOIN sys.dm_db_index_usage_stats AS us
            ON us.database_id = DB_ID()
           AND us.object_id = i.object_id
           AND us.index_id = i.index_id
        WHERE o.is_ms_shipped = 0
          AND o.type IN ('U', 'V')
          AND i.index_id > 0;
    END TRY
    BEGIN CATCH
        SET @SkippedDbs = DB_NAME();
    END CATCH;
END
ELSE
BEGIN
    DECLARE @DbName sysname;
    DECLARE @DbId int;
    DECLARE @Sql nvarchar(max);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name, d.database_id
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state_desc = 'ONLINE'
          AND d.source_database_id IS NULL
          AND d.is_in_standby = 0
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName, @DbId;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'
                SELECT
                    @p_db,
                    COUNT(*),
                    ISNULL(SUM(CASE WHEN i.type_desc = ''NONCLUSTERED'' THEN 1 ELSE 0 END), 0),
                    ISNULL(SUM(CASE WHEN ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0) > 0 THEN 1 ELSE 0 END), 0),
                    ISNULL(SUM(CASE WHEN i.type_desc = ''NONCLUSTERED''
                                     AND ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0) = 0
                                    THEN 1 ELSE 0 END), 0),
                    ISNULL(SUM(CONVERT(bigint, ISNULL(us.user_seeks, 0))), 0),
                    ISNULL(SUM(CONVERT(bigint, ISNULL(us.user_scans, 0))), 0),
                    ISNULL(SUM(CONVERT(bigint, ISNULL(us.user_lookups, 0))), 0),
                    ISNULL(SUM(CONVERT(bigint, ISNULL(us.user_updates, 0))), 0)
                FROM ' + QUOTENAME(@DbName) + N'.sys.indexes AS i
                INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.objects AS o
                    ON o.object_id = i.object_id
                LEFT JOIN sys.dm_db_index_usage_stats AS us
                    ON us.database_id = @p_dbid
                   AND us.object_id = i.object_id
                   AND us.index_id = i.index_id
                WHERE o.is_ms_shipped = 0
                  AND o.type IN (''U'', ''V'')
                  AND i.index_id > 0;';

            INSERT INTO #IndexUsage
            (
                DatabaseName, TotalIndexes, NonClusteredIndexes, UsedIndexes, UnusedNonClustered,
                TotalSeeks, TotalScans, TotalLookups, TotalUpdates
            )
            EXEC sp_executesql @Sql,
                 N'@p_db sysname, @p_dbid int',
                 @p_db = @DbName,
                 @p_dbid = @DbId;
        END TRY
        BEGIN CATCH
            SET @SkippedDbs = @SkippedDbs + CASE WHEN @SkippedDbs = N'' THEN N'' ELSE N', ' END + @DbName;
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName, @DbId;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

-- Ignore databases that contain no user indexes at all
DELETE FROM #IndexUsage WHERE TotalIndexes = 0;

DECLARE @DbCount int = (SELECT COUNT(*) FROM #IndexUsage);
DECLARE @TotalIndexes bigint = ISNULL((SELECT SUM(CONVERT(bigint, TotalIndexes)) FROM #IndexUsage), 0);
DECLARE @TotalNc bigint = ISNULL((SELECT SUM(CONVERT(bigint, NonClusteredIndexes)) FROM #IndexUsage), 0);
DECLARE @TotalUnusedNc bigint = ISNULL((SELECT SUM(CONVERT(bigint, UnusedNonClustered)) FROM #IndexUsage), 0);
DECLARE @Seeks bigint = ISNULL((SELECT SUM(TotalSeeks) FROM #IndexUsage), 0);
DECLARE @Scans bigint = ISNULL((SELECT SUM(TotalScans) FROM #IndexUsage), 0);
DECLARE @Lookups bigint = ISNULL((SELECT SUM(TotalLookups) FROM #IndexUsage), 0);
DECLARE @Updates bigint = ISNULL((SELECT SUM(TotalUpdates) FROM #IndexUsage), 0);

DECLARE @SeekPct decimal(9,2) = CASE WHEN (@Seeks + @Scans) > 0
                                     THEN CONVERT(decimal(9,2), @Seeks * 100.0 / (@Seeks + @Scans))
                                     ELSE NULL END;
DECLARE @UnusedPct decimal(9,2) = CASE WHEN @TotalNc > 0
                                       THEN CONVERT(decimal(9,2), @TotalUnusedNc * 100.0 / @TotalNc)
                                       ELSE NULL END;

DECLARE @DbList nvarchar(max) = N'';

SELECT @DbList = STUFF(
    (SELECT N', ' + u.DatabaseName
     FROM #IndexUsage AS u
     ORDER BY u.DatabaseName
     FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

SET @DbList = ISNULL(@DbList, N'');

DECLARE @DatabaseQueried nvarchar(400);
DECLARE @Score int;
DECLARE @Result nvarchar(10);
DECLARE @Finding nvarchar(max);

IF @DbCount = 0
BEGIN
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
    SET @Score = 0;
END
ELSE
BEGIN
    SET @DatabaseQueried = CASE WHEN LEN(@DbList) > 380 THEN LEFT(@DbList, 377) + N'...' ELSE @DbList END;

    IF (@Seeks + @Scans) = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = N'Found ' + CONVERT(nvarchar(20), @TotalIndexes) + N' index(es) across '
            + CONVERT(nvarchar(20), @DbCount) + N' user database(s), but sys.dm_db_index_usage_stats has recorded zero user seeks and zero user scans'
            + CASE WHEN @StatsWindowDays IS NOT NULL
                   THEN N' over a collection window of ' + CONVERT(nvarchar(20), @StatsWindowDays) + N' day(s) since the last SQL Server start'
                   ELSE N'' END
            + N'. Usage statistics were reset or no workload has run, so index usage has not been analysed against a workload.'
            + CASE WHEN @SkippedDbs <> N'' THEN N' Databases skipped due to access errors: ' + @SkippedDbs + N'.' ELSE N'' END;
    END
    ELSE
    BEGIN
        IF @SeekPct >= 80.0 AND ISNULL(@UnusedPct, 0) <= 10.0
            SET @Score = 3;
        ELSE IF @SeekPct >= 50.0 AND ISNULL(@UnusedPct, 0) <= 30.0
            SET @Score = 2;
        ELSE
            SET @Score = 1;

        SET @Finding = N'Across ' + CONVERT(nvarchar(20), @DbCount) + N' user database(s): '
            + CONVERT(nvarchar(20), @TotalIndexes) + N' index(es) of which ' + CONVERT(nvarchar(20), @TotalNc) + N' nonclustered. '
            + N'Recorded workload: ' + CONVERT(nvarchar(30), @Seeks) + N' user seeks, ' + CONVERT(nvarchar(30), @Scans)
            + N' user scans, ' + CONVERT(nvarchar(30), @Lookups) + N' lookups, ' + CONVERT(nvarchar(30), @Updates) + N' updates. '
            + N'Seek share of reads = ' + CONVERT(nvarchar(20), @SeekPct) + N'%. '
            + N'Never-used nonclustered indexes = ' + CONVERT(nvarchar(20), @TotalUnusedNc)
            + CASE WHEN @UnusedPct IS NOT NULL THEN N' (' + CONVERT(nvarchar(20), @UnusedPct) + N'% of nonclustered)' ELSE N'' END + N'. '
            + CASE WHEN @StatsWindowDays IS NOT NULL
                   THEN N'Statistics collection window: ' + CONVERT(nvarchar(20), @StatsWindowDays) + N' day(s) since SQL Server start. '
                   ELSE N'' END
            + CASE @Score
                   WHEN 3 THEN N'Access is seek-dominated and unused indexes are minimal, consistent with index usage having been analysed against the workload.'
                   WHEN 2 THEN N'Access is only partially seek-dominated and/or a noticeable set of nonclustered indexes is never used - index analysis appears incomplete.'
                   ELSE N'Access is scan-dominated and/or a large proportion of nonclustered indexes is never touched by the workload, indicating index usage has not been analysed against the workload.'
              END
            + CASE WHEN @SkippedDbs <> N'' THEN N' Databases skipped due to access errors: ' + @SkippedDbs + N'.' ELSE N'' END;
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#IndexUsage') IS NOT NULL
    DROP TABLE #IndexUsage;