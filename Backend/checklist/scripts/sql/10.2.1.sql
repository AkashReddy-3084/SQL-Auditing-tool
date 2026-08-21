/* Checklist 10.2.1 - Query Store enabled and configured appropriately
   Read-only: reads catalog views only; the sole writes are to session temp tables. */
SET NOCOUNT ON;

DECLARE @EngineEdition      INT            = TRY_CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @ProductVersion     NVARCHAR(128)  = CONVERT(NVARCHAR(128), SERVERPROPERTY('ProductVersion'));
DECLARE @MajorVersion       INT;
DECLARE @IsSingleDbContext  BIT;
DECLARE @Unsupported        BIT            = 0;
DECLARE @Result             NVARCHAR(50)   = N'Fail';
DECLARE @Score              INT            = 0;
DECLARE @DatabaseQueried    NVARCHAR(4000) = N'';
DECLARE @Finding            NVARCHAR(MAX)  = N'';
DECLARE @Detail             NVARCHAR(MAX)  = NULL;
DECLARE @ErrDetail          NVARCHAR(MAX)  = NULL;
DECLARE @Sql                NVARCHAR(MAX);
DECLARE @DbName             SYSNAME;

SET @MajorVersion = TRY_CONVERT(INT, PARSENAME(@ProductVersion, 4));
SET @IsSingleDbContext = CASE WHEN ISNULL(@EngineEdition, 0) IN (5, 6, 9, 11) THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#QsConfig') IS NOT NULL DROP TABLE #QsConfig;
CREATE TABLE #QsConfig
(
    DatabaseName       SYSNAME      NOT NULL,
    ActualState        TINYINT      NULL,
    ActualStateDesc    NVARCHAR(60) NULL,
    DesiredState       TINYINT      NULL,
    QueryCaptureMode   TINYINT      NULL,
    MaxStorageMB       BIGINT       NULL,
    CurrentStorageMB   BIGINT       NULL,
    StaleThresholdDays BIGINT       NULL,
    SizeBasedCleanup   TINYINT      NULL,
    IsCompliant        BIT          NULL
);

IF OBJECT_ID('tempdb..#QsErrors') IS NOT NULL DROP TABLE #QsErrors;
CREATE TABLE #QsErrors
(
    DatabaseName SYSNAME       NOT NULL,
    ErrorText    NVARCHAR(400) NULL
);

/* Query Store was introduced in SQL Server 2016 (13.x); all Azure SQL surfaces support it. */
IF @IsSingleDbContext = 0 AND ISNULL(@MajorVersion, 0) < 13
    SET @Unsupported = 1;

/* Single-database context (Azure SQL Database and friends): only the current database is reachable. */
IF @Unsupported = 0 AND @IsSingleDbContext = 1
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT DB_NAME(), qso.actual_state, qso.actual_state_desc, qso.desired_state, qso.query_capture_mode, '
                 + N'CONVERT(BIGINT, qso.max_storage_size_mb), CONVERT(BIGINT, qso.current_storage_size_mb), '
                 + N'CONVERT(BIGINT, qso.stale_query_threshold_days), qso.size_based_cleanup_mode '
                 + N'FROM sys.database_query_store_options AS qso;';

        INSERT INTO #QsConfig
            (DatabaseName, ActualState, ActualStateDesc, DesiredState, QueryCaptureMode,
             MaxStorageMB, CurrentStorageMB, StaleThresholdDays, SizeBasedCleanup)
        EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #QsErrors (DatabaseName, ErrorText)
        VALUES (DB_NAME(), LEFT(ERROR_MESSAGE(), 400));
    END CATCH
END

/* Box product, Azure SQL Managed Instance: iterate every eligible user database. */
IF @Unsupported = 0 AND @IsSingleDbContext = 0
BEGIN
    DECLARE qs_db_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0                  /* ONLINE */
          AND d.is_read_only = 0
          AND d.user_access = 0            /* MULTI_USER */
          AND d.is_in_standby = 0
          AND d.source_database_id IS NULL /* exclude snapshots */
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN qs_db_cur;
    FETCH NEXT FROM qs_db_cur INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'SELECT @dbn, qso.actual_state, qso.actual_state_desc, qso.desired_state, qso.query_capture_mode, '
                     + N'CONVERT(BIGINT, qso.max_storage_size_mb), CONVERT(BIGINT, qso.current_storage_size_mb), '
                     + N'CONVERT(BIGINT, qso.stale_query_threshold_days), qso.size_based_cleanup_mode '
                     + N'FROM ' + QUOTENAME(@DbName) + N'.sys.database_query_store_options AS qso;';

            INSERT INTO #QsConfig
                (DatabaseName, ActualState, ActualStateDesc, DesiredState, QueryCaptureMode,
                 MaxStorageMB, CurrentStorageMB, StaleThresholdDays, SizeBasedCleanup)
            EXEC sys.sp_executesql @Sql, N'@dbn SYSNAME', @dbn = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO #QsErrors (DatabaseName, ErrorText)
            VALUES (@DbName, LEFT(ERROR_MESSAGE(), 400));
        END CATCH

        FETCH NEXT FROM qs_db_cur INTO @DbName;
    END

    CLOSE qs_db_cur;
    DEALLOCATE qs_db_cur;
END

UPDATE #QsConfig
SET IsCompliant = CASE
                     WHEN ISNULL(ActualState, -1) = 2
                      AND ISNULL(DesiredState, -1) = 2
                      AND ISNULL(QueryCaptureMode, 0) <> 0
                      AND ISNULL(MaxStorageMB, 0) >= 100
                      AND ISNULL(StaleThresholdDays, 0) >= 30
                     THEN 1 ELSE 0
                  END;

DECLARE @Total      INT = 0;
DECLARE @ReadWrite  INT = 0;
DECLARE @ReadOnly   INT = 0;
DECLARE @OffCount   INT = 0;
DECLARE @ErrorState INT = 0;
DECLARE @Compliant  INT = 0;
DECLARE @ErrCount   INT = 0;

SELECT @Total      = COUNT(*),
       @ReadWrite  = SUM(CASE WHEN ISNULL(q.ActualState, -1) = 2 THEN 1 ELSE 0 END),
       @ReadOnly   = SUM(CASE WHEN ISNULL(q.ActualState, -1) = 1 THEN 1 ELSE 0 END),
       @OffCount   = SUM(CASE WHEN ISNULL(q.ActualState, -1) = 0 THEN 1 ELSE 0 END),
       @ErrorState = SUM(CASE WHEN ISNULL(q.ActualState, -1) = 3 THEN 1 ELSE 0 END),
       @Compliant  = SUM(CASE WHEN q.IsCompliant = 1 THEN 1 ELSE 0 END)
FROM #QsConfig AS q;

SELECT @ErrCount = COUNT(*) FROM #QsErrors;

SELECT @DatabaseQueried = STUFF((
        SELECT N', ' + d.DatabaseName
        FROM (
            SELECT DatabaseName FROM #QsConfig
            UNION
            SELECT DatabaseName FROM #QsErrors
        ) AS d
        ORDER BY d.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

SET @DatabaseQueried = LEFT(ISNULL(NULLIF(@DatabaseQueried, N''), DB_NAME()), 4000);

SELECT @Detail = STUFF((
        SELECT N'; ' + q.DatabaseName
             + N' [state=' + ISNULL(q.ActualStateDesc, N'UNKNOWN')
             + N', desired=' + CONVERT(NVARCHAR(10), ISNULL(q.DesiredState, -1))
             + N', capture_mode=' + CONVERT(NVARCHAR(10), ISNULL(q.QueryCaptureMode, -1))
             + N', max_MB=' + CONVERT(NVARCHAR(20), ISNULL(q.MaxStorageMB, -1))
             + N', used_MB=' + CONVERT(NVARCHAR(20), ISNULL(q.CurrentStorageMB, -1))
             + N', stale_days=' + CONVERT(NVARCHAR(20), ISNULL(q.StaleThresholdDays, -1)) + N']'
        FROM #QsConfig AS q
        WHERE q.IsCompliant = 0
        ORDER BY q.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

SELECT @ErrDetail = STUFF((
        SELECT N'; ' + e.DatabaseName + N' (' + ISNULL(e.ErrorText, N'unknown error') + N')'
        FROM #QsErrors AS e
        ORDER BY e.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

IF @Unsupported = 1
BEGIN
    SET @Score = 0;
    SET @Finding = N'SQL Server version ' + ISNULL(@ProductVersion, N'unknown')
                 + N' does not support Query Store, which requires SQL Server 2016 (13.x) or later. Query Store cannot be enabled or configured on this instance.';
END
ELSE IF @Total = 0 AND @ErrCount = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'No eligible user databases were found on this instance (only system databases, or all user databases are offline, read-only, single-user, snapshots or inaccessible), so there is no Query Store configuration to assess.';
END
ELSE IF @Total = 0 AND @ErrCount > 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'Query Store configuration could not be read from any of the ' + CONVERT(NVARCHAR(10), @ErrCount)
                 + N' database(s) inspected; manual review is required. Errors: ' + ISNULL(@ErrDetail, N'none captured') + N'.';
END
ELSE
BEGIN
    SET @Finding = N'Databases evaluated: ' + CONVERT(NVARCHAR(10), @Total)
                 + N'; Query Store READ_WRITE: ' + CONVERT(NVARCHAR(10), @ReadWrite)
                 + N'; READ_ONLY: ' + CONVERT(NVARCHAR(10), @ReadOnly)
                 + N'; OFF: ' + CONVERT(NVARCHAR(10), @OffCount)
                 + N'; ERROR state: ' + CONVERT(NVARCHAR(10), @ErrorState)
                 + N'; fully compliant (READ_WRITE, desired=actual, capture_mode<>NONE, max_storage_size_mb>=100, stale_query_threshold_days>=30): '
                 + CONVERT(NVARCHAR(10), @Compliant) + N'.';

    IF @Detail IS NOT NULL
        SET @Finding = @Finding + N' Non-compliant databases: ' + @Detail + N'.';

    IF @ErrCount > 0
        SET @Finding = @Finding + N' Databases that could not be inspected (' + CONVERT(NVARCHAR(10), @ErrCount)
                     + N'): ' + ISNULL(@ErrDetail, N'none captured') + N'.';

    IF @Compliant = @Total AND @ErrCount = 0
        SET @Score = 3;
    ELSE IF @ReadWrite = @Total AND @ErrCount = 0
        SET @Score = 2;
    ELSE IF @ReadWrite > 0
        SET @Score = 1;
    ELSE
        SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SET @Finding = LEFT(@Finding, 4000);

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;

IF OBJECT_ID('tempdb..#QsConfig') IS NOT NULL DROP TABLE #QsConfig;
IF OBJECT_ID('tempdb..#QsErrors') IS NOT NULL DROP TABLE #QsErrors;