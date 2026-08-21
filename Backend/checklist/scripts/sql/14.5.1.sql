SET NOCOUNT ON;

DECLARE @StaleDays INT    = 30;
DECLARE @MinRows   BIGINT = 1000;
DECLARE @IsAzureDb BIT    = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 5 THEN 1 ELSE 0 END;
DECLARE @ErrNum    INT    = 0;

IF OBJECT_ID('tempdb..#DbOptions') IS NOT NULL
    DROP TABLE #DbOptions;
IF OBJECT_ID('tempdb..#DbCollect') IS NOT NULL
    DROP TABLE #DbCollect;

CREATE TABLE #DbOptions
(
    DatabaseName           SYSNAME NOT NULL,
    AutoUpdateStatsOn      BIT     NULL,
    AutoCreateStatsOn      BIT     NULL,
    AutoUpdateStatsAsyncOn BIT     NULL
);

CREATE TABLE #DbCollect
(
    DatabaseName      SYSNAME NOT NULL,
    StatsTotal        INT     NULL,
    StatsStale        INT     NULL,
    StatsNeverUpdated INT     NULL
);

INSERT INTO #DbOptions (DatabaseName, AutoUpdateStatsOn, AutoCreateStatsOn, AutoUpdateStatsAsyncOn)
SELECT d.name,
       CAST(d.is_auto_update_stats_on AS BIT),
       CAST(d.is_auto_create_stats_on AS BIT),
       CAST(d.is_auto_update_stats_async_on AS BIT)
FROM sys.databases AS d
WHERE d.state = 0
  AND d.is_read_only = 0
  AND d.name NOT IN (N'master', N'model', N'msdb', N'tempdb')
  AND HAS_DBACCESS(d.name) = 1
  AND (@IsAzureDb = 0 OR d.name = DB_NAME());

IF @IsAzureDb = 1
BEGIN
    BEGIN TRY
        INSERT INTO #DbCollect (DatabaseName, StatsTotal, StatsStale, StatsNeverUpdated)
        SELECT DB_NAME(),
               COUNT(*),
               SUM(CASE WHEN sp.last_updated IS NOT NULL
                         AND sp.[rows] >= @MinRows
                         AND sp.last_updated < DATEADD(DAY, -@StaleDays, SYSDATETIME())
                        THEN 1 ELSE 0 END),
               SUM(CASE WHEN sp.last_updated IS NULL
                         AND ISNULL(sp.[rows], 0) >= @MinRows
                        THEN 1 ELSE 0 END)
        FROM sys.stats AS s
        INNER JOIN sys.objects AS o
            ON o.object_id = s.object_id
        OUTER APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
        WHERE o.is_ms_shipped = 0
          AND o.type = 'U';
    END TRY
    BEGIN CATCH
        SET @ErrNum = ERROR_NUMBER();
    END CATCH;
END
ELSE
BEGIN
    DECLARE @db  SYSNAME;
    DECLARE @sql NVARCHAR(MAX);

    DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT DatabaseName FROM #DbOptions ORDER BY DatabaseName;

    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'USE ' + QUOTENAME(@db) + N';
SELECT DB_NAME() AS DatabaseName,
       COUNT(*) AS StatsTotal,
       SUM(CASE WHEN sp.last_updated IS NOT NULL
                 AND sp.[rows] >= @pMinRows
                 AND sp.last_updated < DATEADD(DAY, -@pStaleDays, SYSDATETIME())
                THEN 1 ELSE 0 END) AS StatsStale,
       SUM(CASE WHEN sp.last_updated IS NULL
                 AND ISNULL(sp.[rows], 0) >= @pMinRows
                THEN 1 ELSE 0 END) AS StatsNeverUpdated
FROM sys.stats AS s
INNER JOIN sys.objects AS o
    ON o.object_id = s.object_id
OUTER APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE o.is_ms_shipped = 0
  AND o.type = ''U'';';

        BEGIN TRY
            INSERT INTO #DbCollect (DatabaseName, StatsTotal, StatsStale, StatsNeverUpdated)
            EXEC sys.sp_executesql
                 @sql,
                 N'@pStaleDays INT, @pMinRows BIGINT',
                 @pStaleDays = @StaleDays,
                 @pMinRows   = @MinRows;
        END TRY
        BEGIN CATCH
            SET @ErrNum = ERROR_NUMBER();
        END CATCH;

        FETCH NEXT FROM db_cur INTO @db;
    END

    CLOSE db_cur;
    DEALLOCATE db_cur;
END

DECLARE @DbCount       INT = (SELECT COUNT(*) FROM #DbOptions);
DECLARE @AutoOff       INT = (SELECT COUNT(*) FROM #DbOptions WHERE AutoUpdateStatsOn = 0);
DECLARE @AutoCreateOff INT = (SELECT COUNT(*) FROM #DbOptions WHERE AutoCreateStatsOn = 0);
DECLARE @NotCollected  INT = (SELECT COUNT(*) FROM #DbOptions AS o
                              WHERE NOT EXISTS (SELECT 1 FROM #DbCollect AS c WHERE c.DatabaseName = o.DatabaseName));
DECLARE @StaleCount    INT = (SELECT ISNULL(SUM(ISNULL(StatsStale, 0)), 0) FROM #DbCollect);
DECLARE @NeverCount    INT = (SELECT ISNULL(SUM(ISNULL(StatsNeverUpdated, 0)), 0) FROM #DbCollect);
DECLARE @DbsWithStale  INT = (SELECT COUNT(*) FROM #DbCollect
                              WHERE (ISNULL(StatsStale, 0) + ISNULL(StatsNeverUpdated, 0)) > 0);

DECLARE @DbList NVARCHAR(MAX) =
    STUFF((SELECT N', ' + DatabaseName
           FROM #DbOptions
           ORDER BY DatabaseName
           FOR XML PATH(N''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @AutoOffList NVARCHAR(MAX) =
    STUFF((SELECT N', ' + DatabaseName
           FROM #DbOptions
           WHERE AutoUpdateStatsOn = 0
           ORDER BY DatabaseName
           FOR XML PATH(N''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @AutoCreateOffList NVARCHAR(MAX) =
    STUFF((SELECT N', ' + DatabaseName
           FROM #DbOptions
           WHERE AutoCreateStatsOn = 0
           ORDER BY DatabaseName
           FOR XML PATH(N''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @StaleList NVARCHAR(MAX) =
    STUFF((SELECT N', ' + DatabaseName + N' (' +
                  CAST(ISNULL(StatsStale, 0) + ISNULL(StatsNeverUpdated, 0) AS NVARCHAR(20)) + N')'
           FROM #DbCollect
           WHERE (ISNULL(StatsStale, 0) + ISNULL(StatsNeverUpdated, 0)) > 0
           ORDER BY DatabaseName
           FOR XML PATH(N''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @NotCollectedList NVARCHAR(MAX) =
    STUFF((SELECT N', ' + o.DatabaseName
           FROM #DbOptions AS o
           WHERE NOT EXISTS (SELECT 1 FROM #DbCollect AS c WHERE c.DatabaseName = o.DatabaseName)
           ORDER BY o.DatabaseName
           FOR XML PATH(N''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @Result  NVARCHAR(50);
DECLARE @Score   INT;
DECLARE @Finding NVARCHAR(MAX);

IF @DbCount = 0
BEGIN
    SET @Score   = 1;
    SET @Finding = N'No accessible online read-write user database was found on this instance, so statistics currency could not be evaluated. Only the system databases master, model, msdb and tempdb are present or accessible to the audit login. Verify database accessibility and audit login permissions.';
END
ELSE IF @AutoOff > 0
BEGIN
    SET @Score   = 1;
    SET @Finding = N'AUTO_UPDATE_STATISTICS is OFF in ' + CAST(@AutoOff AS NVARCHAR(20)) + N' of ' + CAST(@DbCount AS NVARCHAR(20))
                 + N' user database(s): ' + ISNULL(@AutoOffList, N'(none)') + N'.'
                 + CASE WHEN @AutoCreateOff > 0
                        THEN N' AUTO_CREATE_STATISTICS is also OFF in ' + CAST(@AutoCreateOff AS NVARCHAR(20))
                             + N' database(s): ' + ISNULL(@AutoCreateOffList, N'(none)') + N'.'
                        ELSE N'' END
                 + N' Stale statistics (last_updated older than ' + CAST(@StaleDays AS NVARCHAR(10))
                 + N' days on tables of ' + CAST(@MinRows AS NVARCHAR(20)) + N'+ rows): ' + CAST(@StaleCount AS NVARCHAR(20))
                 + N'; never-updated statistics: ' + CAST(@NeverCount AS NVARCHAR(20))
                 + N', across ' + CAST(@DbsWithStale AS NVARCHAR(20)) + N' database(s)'
                 + CASE WHEN @StaleList IS NOT NULL THEN N': ' + @StaleList ELSE N'' END + N'.'
                 + CASE WHEN @NotCollected > 0
                        THEN N' ' + CAST(@NotCollected AS NVARCHAR(20)) + N' database(s) could not be inspected: '
                             + ISNULL(@NotCollectedList, N'(none)') + N'.'
                        ELSE N'' END;
END
ELSE IF @StaleCount = 0 AND @NeverCount = 0 AND @NotCollected = 0 AND @AutoCreateOff = 0
BEGIN
    SET @Score   = 3;
    SET @Finding = N'AUTO_UPDATE_STATISTICS and AUTO_CREATE_STATISTICS are ON in all ' + CAST(@DbCount AS NVARCHAR(20))
                 + N' user database(s) (' + ISNULL(@DbList, N'(none)') + N'), and every one was inspected successfully. No statistic on a table of '
                 + CAST(@MinRows AS NVARCHAR(20)) + N'+ rows is stale (older than ' + CAST(@StaleDays AS NVARCHAR(10))
                 + N' days) or never updated, indicating automatic updates are supplemented by effective manual updates after large loads.';
END
ELSE
BEGIN
    SET @Score   = 2;
    SET @Finding = N'Partial compliance: AUTO_UPDATE_STATISTICS is ON in all ' + CAST(@DbCount AS NVARCHAR(20)) + N' user database(s) ('
                 + ISNULL(@DbList, N'(none)') + N'), but statistics currency gaps remain.'
                 + CASE WHEN @AutoCreateOff > 0
                        THEN N' AUTO_CREATE_STATISTICS is OFF in ' + CAST(@AutoCreateOff AS NVARCHAR(20)) + N' database(s): '
                             + ISNULL(@AutoCreateOffList, N'(none)') + N'.'
                        ELSE N'' END
                 + CASE WHEN (@StaleCount + @NeverCount) > 0
                        THEN N' ' + CAST(@StaleCount AS NVARCHAR(20)) + N' statistic(s) not updated in over ' + CAST(@StaleDays AS NVARCHAR(10))
                             + N' days and ' + CAST(@NeverCount AS NVARCHAR(20)) + N' never-updated statistic(s) on tables of '
                             + CAST(@MinRows AS NVARCHAR(20)) + N'+ rows were found in ' + CAST(@DbsWithStale AS NVARCHAR(20))
                             + N' database(s): ' + ISNULL(@StaleList, N'(none)') + N'.'
                        ELSE N' No stale or never-updated statistics were detected in the databases that were inspected.' END
                 + CASE WHEN @NotCollected > 0
                        THEN N' ' + CAST(@NotCollected AS NVARCHAR(20)) + N' database(s) could not be inspected (insufficient permission or unsupported engine version): '
                             + ISNULL(@NotCollectedList, N'(none)') + N'.'
                        ELSE N'' END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result                                              AS Result,
       @Score                                               AS Score,
       ISNULL(@DbList, CAST(@@SERVERNAME AS NVARCHAR(256))) AS DatabaseQueried,
       @Finding                                             AS Finding;

IF OBJECT_ID('tempdb..#DbOptions') IS NOT NULL
    DROP TABLE #DbOptions;
IF OBJECT_ID('tempdb..#DbCollect') IS NOT NULL
    DROP TABLE #DbCollect;