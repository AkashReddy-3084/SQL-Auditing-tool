SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#QueryStore') IS NOT NULL
    DROP TABLE #QueryStore;

CREATE TABLE #QueryStore
(
    DatabaseName        SYSNAME       NOT NULL,
    ActualState         NVARCHAR(60)  NULL,
    DesiredState        NVARCHAR(60)  NULL,
    CaptureMode         NVARCHAR(60)  NULL,
    StaleThresholdDays  BIGINT        NULL,
    ForcedPlans         INT           NULL,
    FailedForcedPlans   INT           NULL,
    CollectionError     NVARCHAR(400) NULL
);

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @MajorVersion  INT = TRY_CAST(SERVERPROPERTY('ProductMajorVersion') AS INT);

IF @MajorVersion IS NULL
    SET @MajorVersion = TRY_CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)), 4) AS INT);

DECLARE @QueryStoreSupported BIT =
    CASE WHEN @EngineEdition IN (5, 8, 9, 11) OR ISNULL(@MajorVersion, 0) >= 13 THEN 1 ELSE 0 END;

IF @QueryStoreSupported = 1
BEGIN
    IF @EngineEdition = 5
    BEGIN
        BEGIN TRY
            INSERT INTO #QueryStore
                (DatabaseName, ActualState, DesiredState, CaptureMode, StaleThresholdDays, ForcedPlans, FailedForcedPlans)
            SELECT DB_NAME(),
                   o.actual_state_desc,
                   o.desired_state_desc,
                   o.query_capture_mode_desc,
                   CAST(o.stale_query_threshold_days AS BIGINT),
                   (SELECT COUNT(*) FROM sys.query_store_plan AS p  WHERE p.is_forced_plan = 1),
                   (SELECT COUNT(*) FROM sys.query_store_plan AS p2 WHERE p2.is_forced_plan = 1 AND p2.force_failure_count > 0)
            FROM sys.database_query_store_options AS o;
        END TRY
        BEGIN CATCH
            INSERT INTO #QueryStore (DatabaseName, CollectionError)
            VALUES (DB_NAME(), LEFT(ERROR_MESSAGE(), 400));
        END CATCH
    END
    ELSE
    BEGIN
        DECLARE @DbName SYSNAME;
        DECLARE @Sql    NVARCHAR(MAX);

        DECLARE QsDbCursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT d.name
            FROM sys.databases AS d
            WHERE d.database_id > 4
              AND d.state_desc = 'ONLINE'
              AND d.is_in_standby = 0
              AND d.source_database_id IS NULL
              AND HAS_DBACCESS(d.name) = 1
              AND (d.replica_id IS NULL OR sys.fn_hadr_is_primary_replica(d.name) = 1)
            ORDER BY d.name;

        OPEN QsDbCursor;
        FETCH NEXT FROM QsDbCursor INTO @DbName;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @Sql = N'
SELECT @Db AS DatabaseName,
       o.actual_state_desc,
       o.desired_state_desc,
       o.query_capture_mode_desc,
       CAST(o.stale_query_threshold_days AS BIGINT),
       (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.query_store_plan AS p  WHERE p.is_forced_plan = 1),
       (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.query_store_plan AS p2 WHERE p2.is_forced_plan = 1 AND p2.force_failure_count > 0)
FROM ' + QUOTENAME(@DbName) + N'.sys.database_query_store_options AS o;';

                INSERT INTO #QueryStore
                    (DatabaseName, ActualState, DesiredState, CaptureMode, StaleThresholdDays, ForcedPlans, FailedForcedPlans)
                EXEC sp_executesql @Sql, N'@Db SYSNAME', @Db = @DbName;
            END TRY
            BEGIN CATCH
                INSERT INTO #QueryStore (DatabaseName, CollectionError)
                VALUES (@DbName, LEFT(ERROR_MESSAGE(), 400));
            END CATCH

            FETCH NEXT FROM QsDbCursor INTO @DbName;
        END

        CLOSE QsDbCursor;
        DEALLOCATE QsDbCursor;
    END
END

DECLARE @Evaluated     INT = 0,
        @ReadWrite     INT = 0,
        @ReadOnlyState INT = 0,
        @OffState      INT = 0,
        @CaptureNone   INT = 0,
        @ErrorDbs      INT = 0,
        @ForcedPlans   INT = 0,
        @FailedForced  INT = 0;

SELECT @Evaluated     = SUM(CASE WHEN q.CollectionError IS NULL THEN 1 ELSE 0 END),
       @ErrorDbs      = SUM(CASE WHEN q.CollectionError IS NOT NULL THEN 1 ELSE 0 END),
       @ReadWrite     = SUM(CASE WHEN q.ActualState = 'READ_WRITE' THEN 1 ELSE 0 END),
       @ReadOnlyState = SUM(CASE WHEN q.ActualState = 'READ_ONLY' THEN 1 ELSE 0 END),
       @OffState      = SUM(CASE WHEN q.CollectionError IS NULL AND ISNULL(q.ActualState, 'OFF') NOT IN ('READ_WRITE', 'READ_ONLY') THEN 1 ELSE 0 END),
       @CaptureNone   = SUM(CASE WHEN q.ActualState = 'READ_WRITE' AND q.CaptureMode = 'NONE' THEN 1 ELSE 0 END),
       @ForcedPlans   = SUM(ISNULL(q.ForcedPlans, 0)),
       @FailedForced  = SUM(ISNULL(q.FailedForcedPlans, 0))
FROM #QueryStore AS q;

SET @Evaluated     = ISNULL(@Evaluated, 0);
SET @ErrorDbs      = ISNULL(@ErrorDbs, 0);
SET @ReadWrite     = ISNULL(@ReadWrite, 0);
SET @ReadOnlyState = ISNULL(@ReadOnlyState, 0);
SET @OffState      = ISNULL(@OffState, 0);
SET @CaptureNone   = ISNULL(@CaptureNone, 0);
SET @ForcedPlans   = ISNULL(@ForcedPlans, 0);
SET @FailedForced  = ISNULL(@FailedForced, 0);

DECLARE @DatabaseQueried NVARCHAR(MAX) =
    STUFF((SELECT N', ' + q.DatabaseName
           FROM #QueryStore AS q
           ORDER BY q.DatabaseName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

IF @DatabaseQueried IS NULL OR LEN(@DatabaseQueried) = 0
    SET @DatabaseQueried = N'N/A (no user databases)';

DECLARE @OffList NVARCHAR(MAX) =
    STUFF((SELECT N', ' + q.DatabaseName + N' (' + ISNULL(q.ActualState, N'OFF') + N')'
           FROM #QueryStore AS q
           WHERE q.CollectionError IS NULL
             AND ISNULL(q.ActualState, 'OFF') NOT IN ('READ_WRITE')
           ORDER BY q.DatabaseName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @Score  INT;
DECLARE @Result NVARCHAR(20);
DECLARE @Finding NVARCHAR(MAX);

IF @QueryStoreSupported = 0
BEGIN
    SET @Score  = 1;
    SET @Finding = N'This SQL Server version (major version ' + ISNULL(CAST(@MajorVersion AS NVARCHAR(10)), N'unknown')
                 + N') does not support Query Store, so query regressions cannot be detected and plans cannot be forced.';
END
ELSE IF @Evaluated = 0 AND @ErrorDbs = 0
BEGIN
    SET @Score  = 3;
    SET @Finding = N'No accessible user databases were found on this instance, so Query Store regression management is not applicable.';
END
ELSE IF @ReadWrite = @Evaluated AND @Evaluated > 0 AND @CaptureNone = 0 AND @FailedForced = 0 AND @ErrorDbs = 0
BEGIN
    SET @Score  = 3;
    SET @Finding = N'Query Store is ON (READ_WRITE) with an active capture mode on all ' + CAST(@Evaluated AS NVARCHAR(10))
                 + N' user database(s), so regressions are being captured. Forced plans currently in place: '
                 + CAST(@ForcedPlans AS NVARCHAR(10)) + N'; none are failing to apply.';
END
ELSE IF @ReadWrite > 0
BEGIN
    SET @Score  = 2;
    SET @Finding = N'Query Store is READ_WRITE on ' + CAST(@ReadWrite AS NVARCHAR(10)) + N' of '
                 + CAST(@Evaluated AS NVARCHAR(10)) + N' evaluated user database(s), but coverage/configuration is incomplete: '
                 + CAST(@OffState AS NVARCHAR(10)) + N' database(s) OFF, '
                 + CAST(@ReadOnlyState AS NVARCHAR(10)) + N' in READ_ONLY (no new capture), '
                 + CAST(@CaptureNone AS NVARCHAR(10)) + N' with query_capture_mode = NONE, '
                 + CAST(@FailedForced AS NVARCHAR(10)) + N' forced plan(s) failing to apply, '
                 + CAST(@ErrorDbs AS NVARCHAR(10)) + N' database(s) not inspectable. Total forced plans: '
                 + CAST(@ForcedPlans AS NVARCHAR(10))
                 + ISNULL(N'. Not fully enabled on: ' + @OffList, N'') + N'.';
END
ELSE
BEGIN
    SET @Score  = 1;
    SET @Finding = N'Query Store is not in READ_WRITE state on any of the ' + CAST(@Evaluated AS NVARCHAR(10))
                 + N' evaluated user database(s) (' + CAST(@OffState AS NVARCHAR(10)) + N' OFF, '
                 + CAST(@ReadOnlyState AS NVARCHAR(10)) + N' READ_ONLY, '
                 + CAST(@ErrorDbs AS NVARCHAR(10)) + N' not inspectable), so plan regressions are neither detected nor correctable by plan forcing'
                 + ISNULL(N'. Affected: ' + @OffList, N'') + N'.';
END

SET @Result = CASE WHEN @Score = 3 THEN N'Pass' ELSE N'Fail' END;

IF OBJECT_ID('tempdb..#QueryStore') IS NOT NULL
    DROP TABLE #QueryStore;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;