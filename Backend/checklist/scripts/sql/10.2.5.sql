/* Checklist 10.2.5 - Baselines captured for comparison over time
   Scope: SERVER (Azure SQL Database falls back to the current database)
   Read-only: catalog views, msdb metadata and temp tables only. */
SET NOCOUNT ON;

DECLARE @EngineEdition INT = TRY_CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @IsAzureSqlDb  BIT = CASE WHEN TRY_CAST(SERVERPROPERTY('EngineEdition') AS INT) = 5 THEN 1 ELSE 0 END;
DECLARE @MajorVersion  INT = TRY_CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)), 4) AS INT);

IF OBJECT_ID('tempdb..#QueryStore') IS NOT NULL DROP TABLE #QueryStore;
CREATE TABLE #QueryStore
(
    DatabaseName       SYSNAME      NOT NULL,
    ActualState        NVARCHAR(60) NULL,
    DesiredState       NVARCHAR(60) NULL,
    StaleThresholdDays BIGINT       NULL,
    HistoryDays        INT          NULL
);

IF OBJECT_ID('tempdb..#BaselineObjects') IS NOT NULL DROP TABLE #BaselineObjects;
CREATE TABLE #BaselineObjects
(
    DatabaseName SYSNAME NOT NULL,
    TableCount   INT     NOT NULL
);

DECLARE @EvaluatedDbCount INT = 0;

IF @IsAzureSqlDb = 1
BEGIN
    SET @EvaluatedDbCount = 1;

    BEGIN TRY
        INSERT INTO #QueryStore (DatabaseName, ActualState, DesiredState, StaleThresholdDays, HistoryDays)
        SELECT DB_NAME(),
               qso.actual_state_desc,
               qso.desired_state_desc,
               TRY_CAST(qso.stale_query_threshold_days AS BIGINT),
               (SELECT DATEDIFF(DAY, CAST(MIN(i.start_time) AS DATETIME2(0)), SYSUTCDATETIME())
                FROM sys.query_store_runtime_stats_interval AS i)
        FROM sys.database_query_store_options AS qso;
    END TRY
    BEGIN CATCH
        INSERT INTO #QueryStore (DatabaseName, ActualState, DesiredState, StaleThresholdDays, HistoryDays)
        VALUES (DB_NAME(), N'UNKNOWN', N'UNKNOWN', NULL, NULL);
    END CATCH

    BEGIN TRY
        INSERT INTO #BaselineObjects (DatabaseName, TableCount)
        SELECT DB_NAME(), COUNT(*)
        FROM sys.tables AS t
        WHERE t.name LIKE '%baseline%'
           OR t.name LIKE '%perfmon%'
           OR t.name LIKE '%perf%hist%'
           OR t.name LIKE '%wait%stat%hist%'
           OR t.name LIKE '%snapshot%stat%';
    END TRY
    BEGIN CATCH
        SET @EvaluatedDbCount = @EvaluatedDbCount;
    END CATCH
END
ELSE
BEGIN
    DECLARE @db SYSNAME;
    DECLARE @sql NVARCHAR(MAX);

    DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.is_in_standby = 0
          AND d.source_database_id IS NULL
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @EvaluatedDbCount = @EvaluatedDbCount + 1;

        BEGIN TRY
            SET @sql = N'SELECT @p_db,
                                qso.actual_state_desc,
                                qso.desired_state_desc,
                                TRY_CAST(qso.stale_query_threshold_days AS BIGINT),
                                (SELECT DATEDIFF(DAY, CAST(MIN(i.start_time) AS DATETIME2(0)), SYSUTCDATETIME())
                                 FROM ' + QUOTENAME(@db) + N'.sys.query_store_runtime_stats_interval AS i)
                         FROM ' + QUOTENAME(@db) + N'.sys.database_query_store_options AS qso;';

            INSERT INTO #QueryStore (DatabaseName, ActualState, DesiredState, StaleThresholdDays, HistoryDays)
            EXEC sp_executesql @sql, N'@p_db SYSNAME', @p_db = @db;
        END TRY
        BEGIN CATCH
            INSERT INTO #QueryStore (DatabaseName, ActualState, DesiredState, StaleThresholdDays, HistoryDays)
            VALUES (@db, N'UNKNOWN', N'UNKNOWN', NULL, NULL);
        END CATCH

        BEGIN TRY
            SET @sql = N'SELECT @p_db, COUNT(*)
                         FROM ' + QUOTENAME(@db) + N'.sys.tables AS t
                         WHERE t.name LIKE ''%baseline%''
                            OR t.name LIKE ''%perfmon%''
                            OR t.name LIKE ''%perf%hist%''
                            OR t.name LIKE ''%wait%stat%hist%''
                            OR t.name LIKE ''%snapshot%stat%'';';

            INSERT INTO #BaselineObjects (DatabaseName, TableCount)
            EXEC sp_executesql @sql, N'@p_db SYSNAME', @p_db = @db;
        END TRY
        BEGIN CATCH
            SET @sql = NULL;
        END CATCH

        FETCH NEXT FROM db_cur INTO @db;
    END

    CLOSE db_cur;
    DEALLOCATE db_cur;
END

DECLARE @CollectorEnabled      INT = 0;
DECLARE @MdwConfigured         INT = 0;
DECLARE @RunningCollectionSets INT = 0;
DECLARE @BaselineJobs          INT = 0;

IF @IsAzureSqlDb = 0 AND DB_ID('msdb') IS NOT NULL
BEGIN
    BEGIN TRY
        IF OBJECT_ID('msdb.dbo.syscollector_config_store') IS NOT NULL
            SELECT @CollectorEnabled = ISNULL(MAX(CASE WHEN cs.parameter_name = 'CollectorEnabled'
                                                        AND CAST(cs.parameter_value AS NVARCHAR(4000)) = '1'
                                                       THEN 1 ELSE 0 END), 0),
                   @MdwConfigured    = ISNULL(MAX(CASE WHEN cs.parameter_name = 'MDWDatabase'
                                                        AND LEN(LTRIM(RTRIM(ISNULL(CAST(cs.parameter_value AS NVARCHAR(4000)), '')))) > 0
                                                       THEN 1 ELSE 0 END), 0)
            FROM msdb.dbo.syscollector_config_store AS cs;

        IF OBJECT_ID('msdb.dbo.syscollector_collection_sets') IS NOT NULL
            SELECT @RunningCollectionSets = COUNT(*)
            FROM msdb.dbo.syscollector_collection_sets AS c
            WHERE c.is_running = 1;

        IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
            SELECT @BaselineJobs = COUNT(*)
            FROM msdb.dbo.sysjobs AS j
            WHERE j.enabled = 1
              AND (j.name LIKE '%baseline%'
                OR j.name LIKE '%perfmon%'
                OR j.name LIKE '%perf%collect%'
                OR j.name LIKE '%capture%stat%'
                OR j.name LIKE '%collect%stat%');
    END TRY
    BEGIN CATCH
        SET @CollectorEnabled = @CollectorEnabled;
    END CATCH
END

DECLARE @QsReadWrite          INT = (SELECT COUNT(*) FROM #QueryStore WHERE ActualState = N'READ_WRITE');
DECLARE @QsWithHistory        INT = (SELECT COUNT(*) FROM #QueryStore WHERE ActualState = N'READ_WRITE' AND ISNULL(HistoryDays, 0) >= 7);
DECLARE @MaxHistoryDays       INT = (SELECT ISNULL(MAX(HistoryDays), 0) FROM #QueryStore);
DECLARE @DbsWithBaselineTable INT = (SELECT COUNT(*) FROM #BaselineObjects WHERE TableCount > 0);
DECLARE @QsCoveragePct DECIMAL(5,2) =
    CASE WHEN @EvaluatedDbCount > 0
         THEN CAST(@QsReadWrite * 100.0 / @EvaluatedDbCount AS DECIMAL(5,2))
         ELSE CAST(0 AS DECIMAL(5,2)) END;

DECLARE @NoQsList NVARCHAR(1000);
SELECT @NoQsList = STUFF((
        SELECT TOP (5) N', ' + q.DatabaseName
        FROM #QueryStore AS q
        WHERE ISNULL(q.ActualState, N'OFF') <> N'READ_WRITE'
        ORDER BY q.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(1000)'), 1, 2, N'');
SET @NoQsList = ISNULL(@NoQsList, N'none');

DECLARE @QueryStoreOk    BIT = CASE WHEN @EvaluatedDbCount > 0 AND @QsCoveragePct >= 80.0 AND @QsWithHistory > 0 THEN 1 ELSE 0 END;
DECLARE @DataCollectorOk BIT = CASE WHEN @CollectorEnabled = 1 AND @MdwConfigured = 1 AND @RunningCollectionSets > 0 THEN 1 ELSE 0 END;
DECLARE @PartialEvidence BIT = CASE WHEN @QsReadWrite > 0
                                          OR @CollectorEnabled = 1
                                          OR @RunningCollectionSets > 0
                                          OR @BaselineJobs > 0
                                          OR @DbsWithBaselineTable > 0
                                    THEN 1 ELSE 0 END;

DECLARE @Result  NVARCHAR(20);
DECLARE @Score   INT;
DECLARE @Finding NVARCHAR(4000);

DECLARE @Evidence NVARCHAR(2000) =
      N'Databases evaluated: ' + CAST(@EvaluatedDbCount AS NVARCHAR(20))
    + N'; Query Store READ_WRITE: ' + CAST(@QsReadWrite AS NVARCHAR(20))
    + N' (' + CAST(@QsCoveragePct AS NVARCHAR(20)) + N'% coverage)'
    + N'; databases with >= 7 days of retained runtime stats: ' + CAST(@QsWithHistory AS NVARCHAR(20))
    + N'; longest retained history: ' + CAST(@MaxHistoryDays AS NVARCHAR(20)) + N' day(s)'
    + N'; Data Collector enabled: ' + CASE WHEN @CollectorEnabled = 1 THEN N'Yes' ELSE N'No' END
    + N'; MDW configured: ' + CASE WHEN @MdwConfigured = 1 THEN N'Yes' ELSE N'No' END
    + N'; running collection sets: ' + CAST(@RunningCollectionSets AS NVARCHAR(20))
    + N'; enabled baseline-style Agent jobs: ' + CAST(@BaselineJobs AS NVARCHAR(20))
    + N'; databases holding baseline/history tables: ' + CAST(@DbsWithBaselineTable AS NVARCHAR(20))
    + N'; databases without Query Store (first 5): ' + @NoQsList + N'.';

IF @QueryStoreOk = 1 OR @DataCollectorOk = 1
BEGIN
    SET @Score = 3;
    SET @Finding = N'Performance baselines are captured and retained for comparison over time. ' + @Evidence;
END
ELSE IF @PartialEvidence = 1
BEGIN
    SET @Score = 2;
    SET @Finding = N'Baseline capture exists but is incomplete - coverage, retention or the collection configuration does not provide a dependable historical comparison point. ' + @Evidence;
END
ELSE IF @EvaluatedDbCount = 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'No accessible user database was found and no instance-level baseline mechanism was detected, so baseline coverage could not be confirmed. ' + @Evidence;
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = N'No baseline capture mechanism was detected: Query Store is not active, the Data Collector/MDW is not configured, and no baseline jobs or history tables exist. ' + @Evidence;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result,
       @Score  AS Score,
       CASE WHEN @IsAzureSqlDb = 1 THEN DB_NAME() ELSE N'SERVER' END AS DatabaseQueried,
       @Finding AS Finding;