/*=====================================================================
  Checklist ID : 10.1.3
  Description  : Resource utilization trended over time
  Scope        : SERVER
  Type         : Read-only T-SQL
  Compatible   : SQL Server 2016+, Azure SQL Managed Instance,
                 Azure SQL Database (EngineEdition 5)
  Output       : Result, Score, DatabaseQueried, Finding
=====================================================================*/
SET NOCOUNT ON;

DECLARE @IsAzureSqlDb    bit           = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;
DECLARE @MajorVersion    int           = ISNULL(TRY_CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)), 4) AS int), 0);
DECLARE @DatabaseQueried nvarchar(256) = CASE
                                             WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN DB_NAME()
                                             ELSE ISNULL(CAST(SERVERPROPERTY('ServerName') AS nvarchar(256)), CAST(@@SERVERNAME AS nvarchar(256)))
                                         END;

IF OBJECT_ID('tempdb..#QueryStore') IS NOT NULL DROP TABLE #QueryStore;
CREATE TABLE #QueryStore
(
    DatabaseName            sysname      NOT NULL,
    ActualState             nvarchar(60) NULL,
    StaleQueryThresholdDays bigint       NULL
);

DECLARE @sql nvarchar(max);
DECLARE @db  sysname;

/*---------------------------------------------------------------------
  1. Query Store retention (historical per-query CPU / IO / duration)
---------------------------------------------------------------------*/
IF @IsAzureSqlDb = 1
BEGIN
    BEGIN TRY
        SET @sql = N'SELECT DB_NAME(), o.actual_state_desc, CAST(o.stale_query_threshold_days AS bigint) FROM sys.database_query_store_options AS o;';

        INSERT INTO #QueryStore (DatabaseName, ActualState, StaleQueryThresholdDays)
        EXEC sys.sp_executesql @sql;
    END TRY
    BEGIN CATCH
    END CATCH
END
ELSE IF @MajorVersion >= 13
BEGIN
    DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.source_database_id IS NULL
          AND d.is_in_standby = 0
          AND HAS_DBACCESS(d.name) = 1;

    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @db;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @sql = N'SELECT @p_db, o.actual_state_desc, CAST(o.stale_query_threshold_days AS bigint) FROM '
                     + QUOTENAME(@db) + N'.sys.database_query_store_options AS o;';

            INSERT INTO #QueryStore (DatabaseName, ActualState, StaleQueryThresholdDays)
            EXEC sys.sp_executesql @sql, N'@p_db sysname', @p_db = @db;
        END TRY
        BEGIN CATCH
        END CATCH

        FETCH NEXT FROM db_cur INTO @db;
    END
    CLOSE db_cur;
    DEALLOCATE db_cur;
END

DECLARE @UserDbCount int = 0;
IF @IsAzureSqlDb = 1
    SET @UserDbCount = 1;
ELSE
    SELECT @UserDbCount = COUNT(*)
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.source_database_id IS NULL
      AND d.is_in_standby = 0
      AND HAS_DBACCESS(d.name) = 1;

DECLARE @QsReadWrite int = 0;
DECLARE @QsAdequate  int = 0;

SELECT @QsReadWrite = SUM(CASE WHEN q.ActualState = N'READ_WRITE' THEN 1 ELSE 0 END),
       @QsAdequate  = SUM(CASE WHEN q.ActualState = N'READ_WRITE'
                                AND ISNULL(q.StaleQueryThresholdDays, 0) >= 30 THEN 1 ELSE 0 END)
FROM #QueryStore AS q;

SET @QsReadWrite = ISNULL(@QsReadWrite, 0);
SET @QsAdequate  = ISNULL(@QsAdequate, 0);

/*---------------------------------------------------------------------
  2. Data Collector / Management Data Warehouse (non-Azure SQL DB)
  3. Scheduled monitoring / baseline capture Agent jobs
---------------------------------------------------------------------*/
DECLARE @CollectorEnabled      int = 0;
DECLARE @RunningCollectionSets int = 0;
DECLARE @MonitorJobs           int = 0;

IF @IsAzureSqlDb = 0
BEGIN
    BEGIN TRY
        IF OBJECT_ID('msdb.dbo.syscollector_config_store') IS NOT NULL
            SELECT @CollectorEnabled = MAX(CASE WHEN c.parameter_name = N'CollectorEnabled'
                                                 AND CONVERT(nvarchar(64), c.parameter_value) = N'1'
                                                THEN 1 ELSE 0 END)
            FROM msdb.dbo.syscollector_config_store AS c;
    END TRY
    BEGIN CATCH
        SET @CollectorEnabled = 0;
    END CATCH

    BEGIN TRY
        IF OBJECT_ID('msdb.dbo.syscollector_collection_sets') IS NOT NULL
            SELECT @RunningCollectionSets = COUNT(*)
            FROM msdb.dbo.syscollector_collection_sets AS s
            WHERE s.is_running = 1;
    END TRY
    BEGIN CATCH
        SET @RunningCollectionSets = 0;
    END CATCH

    BEGIN TRY
        IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
            SELECT @MonitorJobs = COUNT(*)
            FROM msdb.dbo.sysjobs AS j
            WHERE j.enabled = 1
              AND EXISTS (SELECT 1
                          FROM msdb.dbo.sysjobschedules AS js
                          INNER JOIN msdb.dbo.sysschedules AS sc ON sc.schedule_id = js.schedule_id
                          WHERE js.job_id = j.job_id AND sc.enabled = 1)
              AND (j.name LIKE N'%perfmon%'     OR j.name LIKE N'%perf%'
                OR j.name LIKE N'%monitor%'     OR j.name LIKE N'%utilization%'
                OR j.name LIKE N'%utilisation%' OR j.name LIKE N'%baseline%'
                OR j.name LIKE N'%trend%'       OR j.name LIKE N'%collector%'
                OR j.name LIKE N'%capacity%');
    END TRY
    BEGIN CATCH
        SET @MonitorJobs = 0;
    END CATCH
END

SET @CollectorEnabled = ISNULL(@CollectorEnabled, 0);

/*---------------------------------------------------------------------
  4. Non-default Extended Events sessions persisting to event_file
---------------------------------------------------------------------*/
DECLARE @XeSessions int = 0;

BEGIN TRY
    IF @IsAzureSqlDb = 1
    BEGIN
        IF OBJECT_ID('sys.dm_xe_database_sessions') IS NOT NULL
        BEGIN
            SET @sql = N'SELECT @c = COUNT(DISTINCT s.name)
                         FROM sys.dm_xe_database_sessions AS s
                         INNER JOIN sys.dm_xe_database_session_targets AS t
                                 ON t.event_session_address = s.address
                         WHERE t.target_name = N''event_file'';';
            EXEC sys.sp_executesql @sql, N'@c int OUTPUT', @c = @XeSessions OUTPUT;
        END
    END
    ELSE
    BEGIN
        SET @sql = N'SELECT @c = COUNT(DISTINCT s.name)
                     FROM sys.dm_xe_sessions AS s
                     INNER JOIN sys.dm_xe_session_targets AS t
                             ON t.event_session_address = s.address
                     WHERE t.target_name = N''event_file''
                       AND s.name NOT IN (N''system_health'', N''AlwaysOn_health'',
                                          N''telemetry_xevents'', N''hkenginexesession'');';
        EXEC sys.sp_executesql @sql, N'@c int OUTPUT', @c = @XeSessions OUTPUT;
    END
END TRY
BEGIN CATCH
    SET @XeSessions = 0;
END CATCH

SET @XeSessions = ISNULL(@XeSessions, 0);

/*---------------------------------------------------------------------
  5. Scoring
---------------------------------------------------------------------*/
DECLARE @CollectorRunning bit = CASE WHEN @CollectorEnabled = 1 AND @RunningCollectionSets > 0 THEN 1 ELSE 0 END;
DECLARE @OtherMechanism   bit = CASE WHEN @MonitorJobs > 0 OR @XeSessions > 0 THEN 1 ELSE 0 END;
-- Azure SQL Database always retains 14 days of CPU/IO/memory history in sys.resource_stats.
DECLARE @PlatformTrending bit = @IsAzureSqlDb;

DECLARE @Score int;

IF @UserDbCount > 0
   AND @QsAdequate = @UserDbCount
   AND (@CollectorRunning = 1 OR @OtherMechanism = 1 OR @PlatformTrending = 1)
    SET @Score = 3;
ELSE IF (@UserDbCount > 0 AND @QsReadWrite = @UserDbCount) OR @CollectorRunning = 1
    SET @Score = 2;
ELSE IF @QsReadWrite > 0 OR @OtherMechanism = 1
    SET @Score = 1;
ELSE
    SET @Score = 0;

DECLARE @Result nvarchar(20);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DECLARE @GapList nvarchar(2000) = N'';

SELECT @GapList = STUFF((
        SELECT TOP (10) N', ' + CAST(g.DatabaseName AS nvarchar(128))
        FROM #QueryStore AS g
        WHERE g.ActualState IS NULL
           OR g.ActualState <> N'READ_WRITE'
           OR ISNULL(g.StaleQueryThresholdDays, 0) < 30
        ORDER BY g.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(2000)'), 1, 2, N'');

DECLARE @Finding nvarchar(max) =
      N'Query Store: ' + CAST(@QsReadWrite AS nvarchar(10)) + N' of ' + CAST(@UserDbCount AS nvarchar(10))
    + N' accessible user database(s) READ_WRITE, ' + CAST(@QsAdequate AS nvarchar(10))
    + N' with >= 30 day retention. '
    + N'Data Collector/MDW: '
    + CASE WHEN @IsAzureSqlDb = 1 THEN N'n/a (Azure SQL Database)'
           WHEN @CollectorEnabled = 1 THEN N'enabled, ' + CAST(@RunningCollectionSets AS nvarchar(10)) + N' collection set(s) running'
           ELSE N'not enabled' END + N'. '
    + N'Scheduled monitoring/baseline Agent jobs: '
    + CASE WHEN @IsAzureSqlDb = 1 THEN N'n/a' ELSE CAST(@MonitorJobs AS nvarchar(10)) END + N'. '
    + N'Non-default Extended Events sessions with event_file targets: ' + CAST(@XeSessions AS nvarchar(10)) + N'. '
    + CASE WHEN @IsAzureSqlDb = 1 THEN N'Platform sys.resource_stats retains 14 days of CPU/IO/memory history. ' ELSE N'' END
    + CASE WHEN LEN(ISNULL(@GapList, N'')) > 0
           THEN N'Databases without adequate Query Store retention: ' + @GapList + N'. '
           ELSE N'' END
    + CASE @Score
          WHEN 3 THEN N'Resource utilisation history is retained and can be trended over time.'
          WHEN 2 THEN N'A trending mechanism exists but retention or coverage is incomplete.'
          WHEN 1 THEN N'Only partial or ad-hoc historical capture; utilisation trends cannot be reliably reconstructed.'
          ELSE N'No historical resource utilisation capture found; only point-in-time DMV data is available.'
      END;

IF OBJECT_ID('tempdb..#QueryStore') IS NOT NULL DROP TABLE #QueryStore;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;