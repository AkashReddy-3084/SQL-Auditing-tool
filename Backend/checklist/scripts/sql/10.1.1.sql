/*
    Checklist Item : 10.1.1 - Monitoring solution in place (Azure Monitor / SQL Insights / third-party)
    Area           : Monitoring & Observability
    Scope          : SERVER
    Mode           : READ-ONLY (catalog views and DMVs only; temp table used for aggregation)
    Compatibility  : SQL Server 2012+ , Azure SQL Managed Instance , Azure SQL Database
*/
SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @IsAzureSqlDb  BIT = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 5 THEN 1 ELSE 0 END;
DECLARE @ProductMajor  INT = TRY_CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)), 4) AS INT);
DECLARE @sql           NVARCHAR(MAX);

IF OBJECT_ID('tempdb..#MonitoringSignals') IS NOT NULL
    DROP TABLE #MonitoringSignals;

CREATE TABLE #MonitoringSignals
(
    Category NVARCHAR(60)  NOT NULL,
    Detail   NVARCHAR(400) NOT NULL
);

/* ---------- Signal 1 : Active Extended Events sessions (excluding built-in system sessions) ---------- */
IF @IsAzureSqlDb = 1
BEGIN
    BEGIN TRY
        SET @sql = N'
            SELECT TOP (10) N''Extended Events'', N''Running XE session: '' + s.name
            FROM sys.dm_xe_database_sessions AS s
            WHERE s.name NOT IN (N''system_health'', N''telemetry_xevents'', N''sp_server_diagnostics session'')
            ORDER BY s.name;';
        INSERT INTO #MonitoringSignals (Category, Detail)
        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
    END CATCH;
END
ELSE
BEGIN
    BEGIN TRY
        SET @sql = N'
            SELECT TOP (10) N''Extended Events'', N''Running XE session: '' + s.name
            FROM sys.dm_xe_sessions AS s
            WHERE s.name NOT IN (N''system_health'', N''telemetry_xevents'', N''sp_server_diagnostics session'', N''hkenginexesession'')
            ORDER BY s.name;';
        INSERT INTO #MonitoringSignals (Category, Detail)
        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
    END CATCH;
END;

/* ---------- Signal 2 : SQL Agent alerting (enabled alerts and operators) ---------- */
IF @IsAzureSqlDb = 0
BEGIN
    BEGIN TRY
        SET @sql = N'
            SELECT TOP (10) N''SQL Agent Alerting'', N''Enabled alert: '' + a.name
            FROM msdb.dbo.sysalerts AS a
            WHERE a.enabled = 1
            ORDER BY a.name;';
        INSERT INTO #MonitoringSignals (Category, Detail)
        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
    END CATCH;

    BEGIN TRY
        SET @sql = N'
            SELECT TOP (5) N''SQL Agent Alerting'', N''Enabled operator: '' + o.name
            FROM msdb.dbo.sysoperators AS o
            WHERE o.enabled = 1
            ORDER BY o.name;';
        INSERT INTO #MonitoringSignals (Category, Detail)
        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
    END CATCH;
END;

/* ---------- Signal 3 : Data Collector / Management Data Warehouse ---------- */
IF @IsAzureSqlDb = 0
BEGIN
    BEGIN TRY
        SET @sql = N'
            SELECT TOP (10) N''Data Collector'', N''Running collection set: '' + cs.name
            FROM msdb.dbo.syscollector_collection_sets AS cs
            WHERE cs.is_running = 1
            ORDER BY cs.name;';
        INSERT INTO #MonitoringSignals (Category, Detail)
        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
    END CATCH;
END;

/* ---------- Signal 4 : Query Store enabled (performance telemetry retention) ---------- */
IF @ProductMajor >= 13 OR @IsAzureSqlDb = 1
BEGIN
    BEGIN TRY
        SET @sql = N'
            SELECT TOP (10) N''Query Store'', N''Query Store enabled on database: '' + d.name
            FROM sys.databases AS d
            WHERE d.is_query_store_on = 1
              AND d.state = 0
            ORDER BY d.name;';
        INSERT INTO #MonitoringSignals (Category, Detail)
        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
    END CATCH;
END;

/* ---------- Signal 5 : Connected third-party / cloud monitoring agents ---------- */
BEGIN TRY
    INSERT INTO #MonitoringSignals (Category, Detail)
    SELECT TOP (10) N'Third-Party Monitoring Agent',
           N'Connected monitoring application: ' + LEFT(x.program_name, 200)
    FROM (
        SELECT DISTINCT es.program_name
        FROM sys.dm_exec_sessions AS es
        WHERE es.is_user_process = 1
          AND es.program_name IS NOT NULL
          AND es.program_name <> N''
          AND (   es.program_name LIKE N'%SolarWinds%'
               OR es.program_name LIKE N'%Redgate%'
               OR es.program_name LIKE N'%SQL Monitor%'
               OR es.program_name LIKE N'%Idera%'
               OR es.program_name LIKE N'%Diagnostic Manager%'
               OR es.program_name LIKE N'%Quest%'
               OR es.program_name LIKE N'%Foglight%'
               OR es.program_name LIKE N'%SentryOne%'
               OR es.program_name LIKE N'%SQL Sentry%'
               OR es.program_name LIKE N'%Spotlight%'
               OR es.program_name LIKE N'%ApexSQL%'
               OR es.program_name LIKE N'%dbWatch%'
               OR es.program_name LIKE N'%Datadog%'
               OR es.program_name LIKE N'%New Relic%'
               OR es.program_name LIKE N'%Dynatrace%'
               OR es.program_name LIKE N'%AppDynamics%'
               OR es.program_name LIKE N'%Zabbix%'
               OR es.program_name LIKE N'%Nagios%'
               OR es.program_name LIKE N'%PRTG%'
               OR es.program_name LIKE N'%Azure Monitor%'
               OR es.program_name LIKE N'%SQL Insights%'
               OR es.program_name LIKE N'%OpsManager%'
               OR es.program_name LIKE N'%Telegraf%')
    ) AS x
    ORDER BY x.program_name;
END TRY
BEGIN CATCH
END CATCH;

/* ---------- Evaluate ---------- */
DECLARE @CategoryCount INT = (SELECT COUNT(DISTINCT Category) FROM #MonitoringSignals);
DECLARE @SignalCount   INT = (SELECT COUNT(*) FROM #MonitoringSignals);

DECLARE @CategoryList NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT DISTINCT N', ' + s.Category
                  FROM #MonitoringSignals AS s
                  FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'none');

DECLARE @Evidence NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT N' | ' + s.Category + N': ' + s.Detail
                  FROM #MonitoringSignals AS s
                  ORDER BY s.Category, s.Detail
                  FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 3, N''), N'No monitoring signals detected');

DECLARE @Score  INT;
DECLARE @Result NVARCHAR(20);
DECLARE @Finding NVARCHAR(MAX);

SET @Score = CASE WHEN @CategoryCount >= 2 THEN 3
                  WHEN @CategoryCount = 1 THEN 2
                  ELSE 0 END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding =
    CASE
        WHEN @Score = 3 THEN
            N'A monitoring solution is in place: ' + CAST(@CategoryCount AS NVARCHAR(10))
            + N' distinct monitoring signal categories (' + @CategoryList + N') and '
            + CAST(@SignalCount AS NVARCHAR(10)) + N' individual signals were detected on instance '
            + CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128)) + N'. Evidence: ' + @Evidence
        WHEN @Score = 2 THEN
            N'Only one monitoring signal category (' + @CategoryList + N') was detected on instance '
            + CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128))
            + N'. Monitoring is present but minimal; confirm whether Azure Monitor, SQL Insights or a third-party platform provides full coverage, as those collect out-of-band and may not be visible from T-SQL. Evidence: ' + @Evidence
        ELSE
            N'No monitoring signals were detected on instance '
            + CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128))
            + N': no non-system Extended Events sessions are running, no enabled SQL Agent alerts or operators exist, no Data Collector collection sets are running, Query Store is not enabled on any database, and no known third-party or cloud monitoring agent is connected. There is no evidence that a monitoring solution is in place.'
    END;

SELECT
    @Result                          AS Result,
    @Score                           AS Score,
    CAST(N'SERVER' AS NVARCHAR(128)) AS DatabaseQueried,
    @Finding                         AS Finding;

IF OBJECT_ID('tempdb..#MonitoringSignals') IS NOT NULL
    DROP TABLE #MonitoringSignals;