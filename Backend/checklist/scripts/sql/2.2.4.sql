/* Checklist 2.2.4 - CDC / Change Tracking configured and maintained correctly where used */
/* Read-only: catalog view reads only; #temp tables are the only write targets. */
SET NOCOUNT ON;

DECLARE @IsAzureSqlDb bit = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

DECLARE @Result           nvarchar(20)   = N'Fail';
DECLARE @Score            int            = 0;
DECLARE @DatabaseQueried  nvarchar(4000) = N'SERVER';
DECLARE @Finding          nvarchar(4000) = N'Evaluation did not complete.';

DECLARE @db          sysname;
DECLARE @cdc         bit;
DECLARE @ct          bit;
DECLARE @sql         nvarchar(max);
DECLARE @prefix      nvarchar(300);
DECLARE @cnt         int;
DECLARE @CdcJobsRead bit = 0;

DECLARE @DbCount        int = 0;
DECLARE @UsedCount      int = 0;
DECLARE @CdcCount       int = 0;
DECLARE @CtCount        int = 0;
DECLARE @CdcNoInstances int = 0;
DECLARE @CdcNoJobs      int = 0;
DECLARE @CtNoTables     int = 0;
DECLARE @CtNoCleanup    int = 0;
DECLARE @CtShortRet     int = 0;
DECLARE @Critical       int = 0;
DECLARE @UsedList       nvarchar(max) = N'';
DECLARE @ProblemList    nvarchar(max) = N'';

IF OBJECT_ID('tempdb..#CdcCt') IS NOT NULL DROP TABLE #CdcCt;
CREATE TABLE #CdcCt
(
    DatabaseName        sysname       NOT NULL,
    CdcEnabled          bit           NOT NULL,
    CtEnabled           bit           NOT NULL,
    CdcCaptureInstances int           NULL,
    CtTrackedTables     int           NULL,
    CtAutoCleanup       bit           NULL,
    CtRetentionMinutes  int           NULL,
    CdcCaptureJobs      int           NULL,
    CdcCleanupJobs      int           NULL
);

IF OBJECT_ID('tempdb..#CdcJobs') IS NOT NULL DROP TABLE #CdcJobs;
CREATE TABLE #CdcJobs
(
    DatabaseName sysname NOT NULL,
    CaptureJobs  int     NOT NULL,
    CleanupJobs  int     NOT NULL
);

BEGIN TRY

    /* ---- 1. Enumerate databases and their CDC / CT enablement ---- */
    IF @IsAzureSqlDb = 1
    BEGIN
        INSERT INTO #CdcCt (DatabaseName, CdcEnabled, CtEnabled, CtAutoCleanup, CtRetentionMinutes)
        SELECT d.name,
               CONVERT(bit, d.is_cdc_enabled),
               CASE WHEN ctd.database_id IS NULL THEN CONVERT(bit, 0) ELSE CONVERT(bit, 1) END,
               CONVERT(bit, ctd.is_auto_cleanup_on),
               CASE ctd.retention_period_units
                    WHEN 1 THEN ctd.retention_period
                    WHEN 2 THEN ctd.retention_period * 60
                    WHEN 3 THEN ctd.retention_period * 1440
               END
        FROM sys.databases AS d
        LEFT JOIN sys.change_tracking_databases AS ctd
               ON ctd.database_id = d.database_id
        WHERE d.database_id = DB_ID();
    END
    ELSE
    BEGIN
        INSERT INTO #CdcCt (DatabaseName, CdcEnabled, CtEnabled, CtAutoCleanup, CtRetentionMinutes)
        SELECT d.name,
               CONVERT(bit, d.is_cdc_enabled),
               CASE WHEN ctd.database_id IS NULL THEN CONVERT(bit, 0) ELSE CONVERT(bit, 1) END,
               CONVERT(bit, ctd.is_auto_cleanup_on),
               CASE ctd.retention_period_units
                    WHEN 1 THEN ctd.retention_period
                    WHEN 2 THEN ctd.retention_period * 60
                    WHEN 3 THEN ctd.retention_period * 1440
               END
        FROM sys.databases AS d
        LEFT JOIN sys.change_tracking_databases AS ctd
               ON ctd.database_id = d.database_id
        WHERE d.database_id > 4
          AND d.state_desc = 'ONLINE'
          AND d.is_in_standby = 0
          AND d.source_database_id IS NULL
          AND d.user_access_desc = 'MULTI_USER'
          AND HAS_DBACCESS(d.name) = 1;
    END

    SET @DbCount = (SELECT COUNT(*) FROM #CdcCt);

    /* ---- 2. CDC agent jobs (SQL Agent hosted; not applicable to Azure SQL Database) ---- */
    IF @IsAzureSqlDb = 0 AND EXISTS (SELECT 1 FROM #CdcCt WHERE CdcEnabled = 1)
    BEGIN
        BEGIN TRY
            SET @sql = N'SELECT DB_NAME(cj.database_id) AS DatabaseName,
                                SUM(CASE WHEN cj.job_type = ''capture'' THEN 1 ELSE 0 END) AS CaptureJobs,
                                SUM(CASE WHEN cj.job_type = ''cleanup'' THEN 1 ELSE 0 END) AS CleanupJobs
                         FROM msdb.dbo.cdc_jobs AS cj
                         WHERE DB_NAME(cj.database_id) IS NOT NULL
                         GROUP BY cj.database_id;';

            INSERT INTO #CdcJobs (DatabaseName, CaptureJobs, CleanupJobs)
            EXEC sys.sp_executesql @sql;

            SET @CdcJobsRead = 1;
        END TRY
        BEGIN CATCH
            /* msdb.dbo.cdc_jobs unreadable (permissions or unsupported build) - job state stays unknown */
            SET @CdcJobsRead = 0;
        END CATCH

        IF @CdcJobsRead = 1
        BEGIN
            UPDATE #CdcCt
               SET CdcCaptureJobs = ISNULL((SELECT j.CaptureJobs FROM #CdcJobs AS j WHERE j.DatabaseName = #CdcCt.DatabaseName), 0),
                   CdcCleanupJobs = ISNULL((SELECT j.CleanupJobs FROM #CdcJobs AS j WHERE j.DatabaseName = #CdcCt.DatabaseName), 0)
             WHERE CdcEnabled = 1;
        END
    END

    /* ---- 3. Per-database capture instances / tracked tables ---- */
    DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT DatabaseName, CdcEnabled, CtEnabled
        FROM #CdcCt
        WHERE CdcEnabled = 1 OR CtEnabled = 1;

    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @db, @cdc, @ct;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @prefix = CASE WHEN @IsAzureSqlDb = 1 THEN N'' ELSE QUOTENAME(@db) + N'.' END;

        IF @cdc = 1
        BEGIN
            SET @cnt = NULL;
            BEGIN TRY
                SET @sql = N'SELECT @c = COUNT(*) FROM ' + @prefix + N'cdc.change_tables;';
                EXEC sys.sp_executesql @sql, N'@c int OUTPUT', @c = @cnt OUTPUT;
            END TRY
            BEGIN CATCH
                SET @cnt = NULL;
            END CATCH
            UPDATE #CdcCt SET CdcCaptureInstances = @cnt WHERE DatabaseName = @db;
        END

        IF @ct = 1
        BEGIN
            SET @cnt = NULL;
            BEGIN TRY
                SET @sql = N'SELECT @c = COUNT(*) FROM ' + @prefix + N'sys.change_tracking_tables;';
                EXEC sys.sp_executesql @sql, N'@c int OUTPUT', @c = @cnt OUTPUT;
            END TRY
            BEGIN CATCH
                SET @cnt = NULL;
            END CATCH
            UPDATE #CdcCt SET CtTrackedTables = @cnt WHERE DatabaseName = @db;
        END

        FETCH NEXT FROM db_cur INTO @db, @cdc, @ct;
    END

    CLOSE db_cur;
    DEALLOCATE db_cur;

    /* ---- 4. Aggregate ---- */
    SELECT @UsedCount      = SUM(CASE WHEN CdcEnabled = 1 OR CtEnabled = 1 THEN 1 ELSE 0 END),
           @CdcCount       = SUM(CASE WHEN CdcEnabled = 1 THEN 1 ELSE 0 END),
           @CtCount        = SUM(CASE WHEN CtEnabled = 1 THEN 1 ELSE 0 END),
           @CdcNoInstances = SUM(CASE WHEN CdcEnabled = 1 AND ISNULL(CdcCaptureInstances, 0) = 0 THEN 1 ELSE 0 END),
           @CdcNoJobs      = SUM(CASE WHEN CdcEnabled = 1
                                       AND (ISNULL(CdcCaptureJobs, 1) = 0 OR ISNULL(CdcCleanupJobs, 1) = 0)
                                      THEN 1 ELSE 0 END),
           @CtNoTables     = SUM(CASE WHEN CtEnabled = 1 AND ISNULL(CtTrackedTables, 0) = 0 THEN 1 ELSE 0 END),
           @CtNoCleanup    = SUM(CASE WHEN CtEnabled = 1 AND ISNULL(CtAutoCleanup, 0) = 0 THEN 1 ELSE 0 END),
           @CtShortRet     = SUM(CASE WHEN CtEnabled = 1 AND ISNULL(CtAutoCleanup, 0) = 1
                                       AND ISNULL(CtRetentionMinutes, 1440) < 1440
                                      THEN 1 ELSE 0 END)
    FROM #CdcCt;

    SET @UsedCount      = ISNULL(@UsedCount, 0);
    SET @CdcCount       = ISNULL(@CdcCount, 0);
    SET @CtCount        = ISNULL(@CtCount, 0);
    SET @CdcNoInstances = ISNULL(@CdcNoInstances, 0);
    SET @CdcNoJobs      = ISNULL(@CdcNoJobs, 0);
    SET @CtNoTables     = ISNULL(@CtNoTables, 0);
    SET @CtNoCleanup    = ISNULL(@CtNoCleanup, 0);
    SET @CtShortRet     = ISNULL(@CtShortRet, 0);
    SET @Critical       = @CdcNoInstances + @CdcNoJobs + @CtNoTables + @CtNoCleanup;

    SET @UsedList = ISNULL(STUFF((
            SELECT N', ' + t.DatabaseName + N' ('
                   + CASE WHEN t.CdcEnabled = 1 THEN N'CDC' ELSE N'' END
                   + CASE WHEN t.CdcEnabled = 1 AND t.CtEnabled = 1 THEN N'+' ELSE N'' END
                   + CASE WHEN t.CtEnabled = 1 THEN N'CT' ELSE N'' END + N')'
            FROM #CdcCt AS t
            WHERE t.CdcEnabled = 1 OR t.CtEnabled = 1
            ORDER BY t.DatabaseName
            FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'');

    SET @ProblemList = ISNULL(STUFF((
            SELECT N'; ' + t.DatabaseName + N': '
                   + STUFF(
                       CASE WHEN t.CdcEnabled = 1 AND ISNULL(t.CdcCaptureInstances, 0) = 0
                            THEN N', CDC enabled with 0 capture instances' ELSE N'' END
                     + CASE WHEN t.CdcEnabled = 1 AND ISNULL(t.CdcCaptureJobs, 1) = 0
                            THEN N', CDC capture job missing' ELSE N'' END
                     + CASE WHEN t.CdcEnabled = 1 AND ISNULL(t.CdcCleanupJobs, 1) = 0
                            THEN N', CDC cleanup job missing' ELSE N'' END
                     + CASE WHEN t.CtEnabled = 1 AND ISNULL(t.CtTrackedTables, 0) = 0
                            THEN N', CT enabled with 0 tracked tables' ELSE N'' END
                     + CASE WHEN t.CtEnabled = 1 AND ISNULL(t.CtAutoCleanup, 0) = 0
                            THEN N', CT auto-cleanup OFF' ELSE N'' END
                     + CASE WHEN t.CtEnabled = 1 AND ISNULL(t.CtAutoCleanup, 0) = 1 AND ISNULL(t.CtRetentionMinutes, 1440) < 1440
                            THEN N', CT retention ' + CONVERT(nvarchar(20), t.CtRetentionMinutes) + N' min (< 1 day)' ELSE N'' END
                       , 1, 2, N'')
            FROM #CdcCt AS t
            WHERE (t.CdcEnabled = 1 AND ISNULL(t.CdcCaptureInstances, 0) = 0)
               OR (t.CdcEnabled = 1 AND (ISNULL(t.CdcCaptureJobs, 1) = 0 OR ISNULL(t.CdcCleanupJobs, 1) = 0))
               OR (t.CtEnabled = 1 AND ISNULL(t.CtTrackedTables, 0) = 0)
               OR (t.CtEnabled = 1 AND ISNULL(t.CtAutoCleanup, 0) = 0)
               OR (t.CtEnabled = 1 AND ISNULL(t.CtAutoCleanup, 0) = 1 AND ISNULL(t.CtRetentionMinutes, 1440) < 1440)
            ORDER BY t.DatabaseName
            FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'');

    /* ---- 5. Score ---- */
    IF @DbCount = 0
    BEGIN
        SET @Score           = 0;
        SET @DatabaseQueried = N'NONE';
        SET @Finding         = N'No accessible online user database was found on this instance, so CDC / Change Tracking configuration could not be assessed.';
    END
    ELSE IF @UsedCount = 0
    BEGIN
        SET @Score           = 3;
        SET @DatabaseQueried = N'ALL USER DATABASES (' + CONVERT(nvarchar(10), @DbCount) + N' scanned)';
        SET @Finding         = N'Neither CDC nor Change Tracking is enabled on any of the ' + CONVERT(nvarchar(10), @DbCount)
                             + N' accessible user database(s). The requirement is conditional ("where used"), so there is no CDC/CT configuration to maintain.';
    END
    ELSE
    BEGIN
        SET @DatabaseQueried = LEFT(@UsedList, 3900);

        IF @Critical > 0
        BEGIN
            SET @Score   = 1;
            SET @Finding = LEFT(N'CDC/Change Tracking is in use on ' + CONVERT(nvarchar(10), @UsedCount) + N' database(s) (CDC: '
                         + CONVERT(nvarchar(10), @CdcCount) + N', CT: ' + CONVERT(nvarchar(10), @CtCount)
                         + N') but critical maintenance gaps were found - ' + @ProblemList + N'.', 3900);
        END
        ELSE IF @CtShortRet > 0
        BEGIN
            SET @Score   = 2;
            SET @Finding = LEFT(N'CDC/Change Tracking is in use on ' + CONVERT(nvarchar(10), @UsedCount)
                         + N' database(s) and is structurally correct, but Change Tracking retention is shorter than 1 day on '
                         + CONVERT(nvarchar(10), @CtShortRet) + N' database(s) - ' + @ProblemList + N'.', 3900);
        END
        ELSE
        BEGIN
            SET @Score   = 3;
            SET @Finding = LEFT(N'CDC/Change Tracking is in use on ' + CONVERT(nvarchar(10), @UsedCount) + N' database(s) (CDC: '
                         + CONVERT(nvarchar(10), @CdcCount) + N', CT: ' + CONVERT(nvarchar(10), @CtCount)
                         + N') and is correctly configured: every CDC database has capture instances'
                         + CASE WHEN @IsAzureSqlDb = 0 THEN N' plus capture and cleanup jobs' ELSE N'' END
                         + N', and every Change Tracking database has tracked tables with auto-cleanup ON and retention of at least 1 day. Databases: '
                         + @UsedList + N'.', 3900);
        END
    END

END TRY
BEGIN CATCH

    IF CURSOR_STATUS('local', 'db_cur') > -2
    BEGIN
        IF CURSOR_STATUS('local', 'db_cur') > -1 CLOSE db_cur;
        DEALLOCATE db_cur;
    END

    SET @Score           = 0;
    SET @DatabaseQueried = N'SERVER';
    SET @Finding         = LEFT(N'CDC / Change Tracking configuration could not be evaluated because the collection failed: '
                              + ERROR_MESSAGE() + N' (error ' + CONVERT(nvarchar(20), ERROR_NUMBER()) + N').', 3900);

END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;

IF OBJECT_ID('tempdb..#CdcJobs') IS NOT NULL DROP TABLE #CdcJobs;
IF OBJECT_ID('tempdb..#CdcCt') IS NOT NULL DROP TABLE #CdcCt;