SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @IsAzureSqlDb BIT = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) IN (5, 6, 9, 11) THEN 1 ELSE 0 END;
DECLARE @DatabaseQueried NVARCHAR(256) = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) IN (5, 6, 9, 11) THEN DB_NAME() ELSE N'master' END;

DECLARE @UserDbCount INT = 0;
DECLARE @QueryStoreDbCount INT = 0;
DECLARE @WaitXeSessions INT = 0;
DECLARE @RunningXeSessions INT = 0;
DECLARE @DataCollectorEnabled INT = 0;
DECLARE @RunningCollectionSets INT = 0;
DECLARE @PerfMonitoringJobs INT = 0;
DECLARE @PlatformTelemetry INT = 0;
DECLARE @Indicators INT = 0;
DECLARE @Score INT;
DECLARE @Result NVARCHAR(20);
DECLARE @Finding NVARCHAR(4000);
DECLARE @sql NVARCHAR(MAX);

/* Indicator 3: Query Store coverage over online, writable user databases */
IF COL_LENGTH('sys.databases', 'is_query_store_on') IS NOT NULL
BEGIN
    BEGIN TRY
        SET @sql = N'SELECT @u = COUNT(*), @q = SUM(CASE WHEN is_query_store_on = 1 THEN 1 ELSE 0 END)
                     FROM sys.databases
                     WHERE database_id > 4 AND state_desc = N''ONLINE'' AND is_read_only = 0;';
        EXEC sys.sp_executesql @sql,
             N'@u INT OUTPUT, @q INT OUTPUT',
             @u = @UserDbCount OUTPUT, @q = @QueryStoreDbCount OUTPUT;
    END TRY
    BEGIN CATCH
        SET @UserDbCount = 0;
        SET @QueryStoreDbCount = 0;
    END CATCH;
END;

SET @UserDbCount = ISNULL(@UserDbCount, 0);
SET @QueryStoreDbCount = ISNULL(@QueryStoreDbCount, 0);

/* Indicator 2: Extended Events sessions capturing wait / resource / CPU / IO events */
BEGIN TRY
    IF @IsAzureSqlDb = 1
        SET @sql = N'SELECT @w = COUNT(DISTINCT es.event_session_id)
                     FROM sys.database_event_sessions AS es
                     INNER JOIN sys.database_event_session_events AS ev
                         ON ev.event_session_id = es.event_session_id
                     WHERE ev.name LIKE N''%wait%''
                        OR ev.name LIKE N''%resource%''
                        OR ev.name LIKE N''%cpu%''
                        OR ev.name LIKE N''%io_%'';
                     SELECT @r = COUNT(*) FROM sys.dm_xe_database_sessions;';
    ELSE
        SET @sql = N'SELECT @w = COUNT(DISTINCT es.event_session_id)
                     FROM sys.server_event_sessions AS es
                     INNER JOIN sys.server_event_session_events AS ev
                         ON ev.event_session_id = es.event_session_id
                     WHERE es.name NOT IN (N''system_health'', N''AlwaysOn_health'')
                       AND (ev.name LIKE N''%wait%''
                         OR ev.name LIKE N''%resource%''
                         OR ev.name LIKE N''%cpu%''
                         OR ev.name LIKE N''%io_%'');
                     SELECT @r = COUNT(*)
                     FROM sys.dm_xe_sessions
                     WHERE name NOT IN (N''system_health'', N''AlwaysOn_health'')
                       AND name NOT LIKE N''hkenginexesession%'';';

    EXEC sys.sp_executesql @sql,
         N'@w INT OUTPUT, @r INT OUTPUT',
         @w = @WaitXeSessions OUTPUT, @r = @RunningXeSessions OUTPUT;
END TRY
BEGIN CATCH
    SET @WaitXeSessions = 0;
    SET @RunningXeSessions = 0;
END CATCH;

SET @WaitXeSessions = ISNULL(@WaitXeSessions, 0);
SET @RunningXeSessions = ISNULL(@RunningXeSessions, 0);

/* Indicators 1 and 4: Data Collector / MDW and metric-collection Agent jobs, or Azure platform telemetry */
IF @IsAzureSqlDb = 0 AND DB_ID('msdb') IS NOT NULL
BEGIN
    BEGIN TRY
        SET @sql = N'SELECT @e = COUNT(*)
                     FROM msdb.dbo.syscollector_config_store
                     WHERE parameter_name = N''CollectorEnabled'' AND parameter_value = N''1'';';
        EXEC sys.sp_executesql @sql, N'@e INT OUTPUT', @e = @DataCollectorEnabled OUTPUT;
    END TRY
    BEGIN CATCH
        SET @DataCollectorEnabled = 0;
    END CATCH;

    BEGIN TRY
        SET @sql = N'SELECT @c = COUNT(*) FROM msdb.dbo.syscollector_collection_sets WHERE is_running = 1;';
        EXEC sys.sp_executesql @sql, N'@c INT OUTPUT', @c = @RunningCollectionSets OUTPUT;
    END TRY
    BEGIN CATCH
        SET @RunningCollectionSets = 0;
    END CATCH;

    BEGIN TRY
        SET @sql = N'SELECT @j = COUNT(*)
                     FROM msdb.dbo.sysjobs
                     WHERE enabled = 1
                       AND (name LIKE N''%perf%''
                         OR name LIKE N''%monitor%''
                         OR name LIKE N''%metric%''
                         OR name LIKE N''%baseline%''
                         OR name LIKE N''%wait stat%''
                         OR name LIKE N''%collect%'');';
        EXEC sys.sp_executesql @sql, N'@j INT OUTPUT', @j = @PerfMonitoringJobs OUTPUT;
    END TRY
    BEGIN CATCH
        SET @PerfMonitoringJobs = 0;
    END CATCH;
END
ELSE IF @IsAzureSqlDb = 1
BEGIN
    BEGIN TRY
        SET @sql = N'SELECT @p = CASE WHEN EXISTS (SELECT 1 FROM sys.dm_db_resource_stats) THEN 1 ELSE 0 END;';
        EXEC sys.sp_executesql @sql, N'@p INT OUTPUT', @p = @PlatformTelemetry OUTPUT;
    END TRY
    BEGIN CATCH
        SET @PlatformTelemetry = 0;
    END CATCH;
END;

SET @DataCollectorEnabled = ISNULL(@DataCollectorEnabled, 0);
SET @RunningCollectionSets = ISNULL(@RunningCollectionSets, 0);
SET @PerfMonitoringJobs = ISNULL(@PerfMonitoringJobs, 0);
SET @PlatformTelemetry = ISNULL(@PlatformTelemetry, 0);

SET @Indicators =
      CASE WHEN @DataCollectorEnabled > 0 OR @RunningCollectionSets > 0 OR @PlatformTelemetry > 0 THEN 1 ELSE 0 END
    + CASE WHEN @WaitXeSessions > 0 THEN 1 ELSE 0 END
    + CASE WHEN @UserDbCount > 0 AND @QueryStoreDbCount = @UserDbCount THEN 1 ELSE 0 END
    + CASE WHEN @PerfMonitoringJobs > 0 THEN 1 ELSE 0 END;

SET @Score = CASE WHEN @Indicators >= 2 THEN 3
                  WHEN @Indicators = 1 THEN 2
                  ELSE 1 END;

SET @Result = CASE WHEN @Score = 3 THEN N'Pass' ELSE N'Fail' END;

SET @Finding = CONCAT(
      N'Engine edition ', @EngineEdition,
      N'. Key-metric collection indicators detected: ', @Indicators, N' of 4.',
      N' Query Store enabled on ', @QueryStoreDbCount, N' of ', @UserDbCount, N' online writable user database(s).',
      N' Extended Events session(s) defined with wait/resource/CPU/IO events: ', @WaitXeSessions,
      N' (non-default XE sessions currently running: ', @RunningXeSessions, N').',
      CASE WHEN @IsAzureSqlDb = 1
           THEN CONCAT(N' Platform resource telemetry (sys.dm_db_resource_stats: CPU, DTU/vCore, IO, memory) available: ',
                       CASE WHEN @PlatformTelemetry > 0 THEN N'YES' ELSE N'NO' END, N'.')
           ELSE CONCAT(N' Data Collector enabled: ', CASE WHEN @DataCollectorEnabled > 0 THEN N'YES' ELSE N'NO' END,
                       N'; collection sets running: ', @RunningCollectionSets,
                       N'; enabled Agent jobs named for performance/metric collection: ', @PerfMonitoringJobs, N'.')
      END,
      CASE WHEN @Score = 3 THEN N' Two or more independent mechanisms are actively capturing key resource metrics.'
           WHEN @Score = 2 THEN N' Only one collection mechanism is active, so CPU, memory, IO, DTU/vCore and wait coverage is partial.'
           ELSE N' No evidence of ongoing collection of CPU, memory, IO, DTU/vCore or wait statistics was found.'
      END);

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;