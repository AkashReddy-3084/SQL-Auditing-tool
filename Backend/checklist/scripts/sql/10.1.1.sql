-- Checklist: Monitoring solution in place (Azure Monitor / SQL Insights / third-party)
-- Scope: SERVER
-- Scoring: 3 = two or more distinct monitoring signal categories; 2 = one active monitoring or alerting category; 1 = Query Store telemetry retention only; 0 = no monitoring signal

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No monitoring signals were detected on this instance';
DECLARE @Engine INT = ISNULL(CONVERT(INT, SERVERPROPERTY('EngineEdition')), 0);
DECLARE @Categories INT = 0;
DECLARE @QueryStoreOnly INT = 0;
DECLARE @Evidence NVARCHAR(MAX) = 'none';
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #Signals (Category NVARCHAR(60) NOT NULL, Detail NVARCHAR(300) NOT NULL);

BEGIN TRY
    SET @Sql = CASE WHEN @Engine = 5
        THEN N'SELECT TOP (5) N''Extended Events'', N''running session '' + name FROM sys.dm_xe_database_sessions WHERE name NOT IN (N''system_health'', N''telemetry_xevents'') ORDER BY name;'
        ELSE N'SELECT TOP (5) N''Extended Events'', N''running session '' + name FROM sys.dm_xe_sessions WHERE name NOT IN (N''system_health'', N''telemetry_xevents'', N''sp_server_diagnostics session'', N''hkenginexesession'') ORDER BY name;' END;
    INSERT INTO #Signals (Category, Detail) EXEC sys.sp_executesql @Sql;
END TRY
BEGIN CATCH
    SET @Sql = NULL;
END CATCH;

IF @Engine <> 5
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT TOP (5) N''SQL Agent Alerting'', N''enabled alert '' + name FROM msdb.dbo.sysalerts WHERE enabled = 1 ORDER BY name;';
        INSERT INTO #Signals (Category, Detail) EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        SET @Sql = NULL;
    END CATCH;

    BEGIN TRY
        SET @Sql = N'SELECT TOP (5) N''Data Collector'', N''running collection set '' + name FROM msdb.dbo.syscollector_collection_sets WHERE is_running = 1 ORDER BY name;';
        INSERT INTO #Signals (Category, Detail) EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        SET @Sql = NULL;
    END CATCH;
END

BEGIN TRY
    SET @Sql = N'SELECT TOP (5) N''Query Store'', N''Query Store enabled on '' + name FROM sys.databases WHERE is_query_store_on = 1 AND state = 0 ORDER BY name;';
    INSERT INTO #Signals (Category, Detail) EXEC sys.sp_executesql @Sql;
END TRY
BEGIN CATCH
    SET @Sql = NULL;
END CATCH;

BEGIN TRY
    INSERT INTO #Signals (Category, Detail)
    SELECT DISTINCT TOP (5) N'Monitoring Agent', N'connected application ' + LEFT(program_name, 200)
    FROM sys.dm_exec_sessions
    WHERE is_user_process = 1
      AND program_name IS NOT NULL
      AND (program_name LIKE N'%SolarWinds%' OR program_name LIKE N'%Redgate%'
           OR program_name LIKE N'%SQL Monitor%' OR program_name LIKE N'%Idera%'
           OR program_name LIKE N'%Quest%' OR program_name LIKE N'%Foglight%'
           OR program_name LIKE N'%SentryOne%' OR program_name LIKE N'%SQL Sentry%'
           OR program_name LIKE N'%Spotlight%' OR program_name LIKE N'%Datadog%'
           OR program_name LIKE N'%New Relic%' OR program_name LIKE N'%Dynatrace%'
           OR program_name LIKE N'%AppDynamics%' OR program_name LIKE N'%Zabbix%'
           OR program_name LIKE N'%Nagios%' OR program_name LIKE N'%PRTG%'
           OR program_name LIKE N'%Azure Monitor%' OR program_name LIKE N'%SQL Insights%'
           OR program_name LIKE N'%Telegraf%' OR program_name LIKE N'%OpsManager%');
END TRY
BEGIN CATCH
    SET @Sql = NULL;
END CATCH;

SELECT @Categories = COUNT(DISTINCT Category) FROM #Signals;

SELECT @QueryStoreOnly = CASE WHEN @Categories = 1
                                   AND MAX(CASE WHEN Category = N'Query Store' THEN 1 ELSE 0 END) = 1
                              THEN 1 ELSE 0 END
FROM #Signals;

SELECT @Evidence = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX), Category + N': ' + Detail), '; '), 'none')
FROM #Signals;

DROP TABLE #Signals;

SET @Categories = ISNULL(@Categories, 0);
SET @QueryStoreOnly = ISNULL(@QueryStoreOnly, 0);
SET @Evidence = ISNULL(@Evidence, 'none');

SET @Score = CASE
    WHEN @Categories >= 2 THEN 3
    WHEN @QueryStoreOnly = 1 THEN 1
    WHEN @Categories = 1 THEN 2
    ELSE 0
END;

SET @Finding = CASE
    WHEN @Categories = 0
        THEN 'No monitoring signals found: no non-default Extended Events session is running, no enabled SQL Agent alert or running data collector set exists, Query Store is enabled on no database, and no known third-party or cloud monitoring agent is connected.'
    WHEN @QueryStoreOnly = 1
        THEN CONCAT('Query Store is the only monitoring signal found (', LEFT(@Evidence, 1200),
             '); it retains query telemetry but no alerting or external monitoring collector was detected.')
    ELSE CONCAT(@Categories, ' distinct monitoring signal category/categories found: ', LEFT(@Evidence, 1200), '.')
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;