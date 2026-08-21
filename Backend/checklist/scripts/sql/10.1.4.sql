/* Checklist 10.1.4 - Alerts configured for resource saturation and errors
   Scope: SERVER. Strictly read-only: catalog/DMV reads only. */
SET NOCOUNT ON;

DECLARE @EngineEdition   int            = CAST(SERVERPROPERTY('EngineEdition') AS int);
DECLARE @Result          nvarchar(50);
DECLARE @Score           int            = 1;
DECLARE @DatabaseQueried nvarchar(128)  = N'msdb';
DECLARE @Finding         nvarchar(4000) = N'';

DECLARE @TotalAlerts      int = 0,
        @EnabledAlerts    int = 0,
        @ErrorAlerts      int = 0,
        @PerfAlerts       int = 0,
        @WmiAlerts        int = 0,
        @AlertsNoResponse int = 0,
        @EnabledOperators int = 0;
DECLARE @AgentStatus nvarchar(64) = N'unknown';

IF @EngineEdition = 5
BEGIN
    SET @DatabaseQueried = DB_NAME();
    SET @Score           = 0;
    SET @Finding         = N'Engine edition is Azure SQL Database (EngineEdition 5). SQL Server Agent and the msdb alerting catalog are not available on this platform, so resource-saturation and error alerting must be delivered by Azure Monitor / Log Analytics alert rules outside the database engine. Those platform alert rules cannot be read from the engine, so this control could not be verified and requires manual review.';
END
ELSE
BEGIN
    DECLARE @msdb   nvarchar(128) = QUOTENAME(N'msdb');
    DECLARE @sql    nvarchar(max);
    DECLARE @params nvarchar(max);

    SET @params = N'@TotalAlertsOut int OUTPUT, @EnabledAlertsOut int OUTPUT, @ErrorAlertsOut int OUTPUT, @PerfAlertsOut int OUTPUT, @WmiAlertsOut int OUTPUT, @AlertsNoResponseOut int OUTPUT, @EnabledOperatorsOut int OUTPUT';

    SET @sql = N'
SELECT
    @TotalAlertsOut      = COUNT(*),
    @EnabledAlertsOut    = SUM(CASE WHEN a.enabled = 1 THEN 1 ELSE 0 END),
    @ErrorAlertsOut      = SUM(CASE WHEN a.enabled = 1 AND a.severity BETWEEN 17 AND 25 THEN 1 ELSE 0 END),
    @PerfAlertsOut       = SUM(CASE WHEN a.enabled = 1 AND a.performance_condition IS NOT NULL AND LTRIM(RTRIM(a.performance_condition)) <> N'''' THEN 1 ELSE 0 END),
    @WmiAlertsOut        = SUM(CASE WHEN a.enabled = 1 AND a.wmi_query IS NOT NULL AND LTRIM(RTRIM(a.wmi_query)) <> N'''' THEN 1 ELSE 0 END),
    @AlertsNoResponseOut = SUM(CASE WHEN a.enabled = 1 AND ISNULL(a.has_notification, 0) = 0 AND a.job_id = CAST(N''00000000-0000-0000-0000-000000000000'' AS uniqueidentifier) THEN 1 ELSE 0 END)
FROM ' + @msdb + N'.dbo.sysalerts AS a;

SELECT @EnabledOperatorsOut = COUNT(*)
FROM ' + @msdb + N'.dbo.sysoperators AS o
WHERE o.enabled = 1
  AND (   (o.email_address   IS NOT NULL AND LTRIM(RTRIM(o.email_address))   <> N'''')
       OR (o.pager_address   IS NOT NULL AND LTRIM(RTRIM(o.pager_address))   <> N'''')
       OR (o.netsend_address IS NOT NULL AND LTRIM(RTRIM(o.netsend_address)) <> N'''') );';

    EXEC sys.sp_executesql @sql, @params,
         @TotalAlertsOut      = @TotalAlerts      OUTPUT,
         @EnabledAlertsOut    = @EnabledAlerts    OUTPUT,
         @ErrorAlertsOut      = @ErrorAlerts      OUTPUT,
         @PerfAlertsOut       = @PerfAlerts       OUTPUT,
         @WmiAlertsOut        = @WmiAlerts        OUTPUT,
         @AlertsNoResponseOut = @AlertsNoResponse OUTPUT,
         @EnabledOperatorsOut = @EnabledOperators OUTPUT;

    SET @TotalAlerts      = ISNULL(@TotalAlerts, 0);
    SET @EnabledAlerts    = ISNULL(@EnabledAlerts, 0);
    SET @ErrorAlerts      = ISNULL(@ErrorAlerts, 0);
    SET @PerfAlerts       = ISNULL(@PerfAlerts, 0);
    SET @WmiAlerts        = ISNULL(@WmiAlerts, 0);
    SET @AlertsNoResponse = ISNULL(@AlertsNoResponse, 0);
    SET @EnabledOperators = ISNULL(@EnabledOperators, 0);

    IF EXISTS (SELECT 1 FROM sys.all_objects WHERE name = N'dm_server_services' AND schema_id = SCHEMA_ID(N'sys'))
    BEGIN
        SET @sql = N'SELECT TOP (1) @AgentStatusOut = s.status_desc FROM sys.dm_server_services AS s WHERE s.servicename LIKE N''SQL Server Agent%'';';
        BEGIN TRY
            EXEC sys.sp_executesql @sql, N'@AgentStatusOut nvarchar(64) OUTPUT', @AgentStatusOut = @AgentStatus OUTPUT;
        END TRY
        BEGIN CATCH
            SET @AgentStatus = N'unknown';
        END CATCH
        SET @AgentStatus = ISNULL(@AgentStatus, N'unknown');
    END

    DECLARE @PerfRequirementMet bit = CASE WHEN @PerfAlerts > 0 OR @EngineEdition = 8 THEN 1 ELSE 0 END;

    IF @EnabledAlerts = 0
        SET @Score = 1;
    ELSE IF @ErrorAlerts > 0 AND @PerfRequirementMet = 1 AND @AlertsNoResponse = 0 AND @EnabledOperators > 0
        SET @Score = 3;
    ELSE IF @ErrorAlerts > 0 AND @PerfRequirementMet = 1
        SET @Score = 2;
    ELSE
        SET @Score = 1;

    SET @Finding =
        N'SQL Server Agent alerting on instance ' + ISNULL(CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)), N'(unknown)')
      + N' (EngineEdition ' + CAST(@EngineEdition AS nvarchar(10)) + N', Agent service state: ' + @AgentStatus + N'): '
      + CAST(@TotalAlerts AS nvarchar(10)) + N' alert(s) defined, ' + CAST(@EnabledAlerts AS nvarchar(10)) + N' enabled. '
      + N'Enabled error-severity alerts (severity 17-25): ' + CAST(@ErrorAlerts AS nvarchar(10)) + N'. '
      + N'Enabled resource-saturation (performance condition) alerts: ' + CAST(@PerfAlerts AS nvarchar(10)) + N'. '
      + N'Enabled WMI alerts: ' + CAST(@WmiAlerts AS nvarchar(10)) + N'. '
      + N'Enabled alerts with no response route (no operator notification and no response job): ' + CAST(@AlertsNoResponse AS nvarchar(10)) + N'. '
      + N'Enabled operators with a delivery address: ' + CAST(@EnabledOperators AS nvarchar(10)) + N'. '
      + CASE
            WHEN @EnabledAlerts = 0
                THEN N'No enabled alerts are defined, so neither resource saturation nor error conditions are alerted on.'
            WHEN @Score = 3
                THEN N'Both error-condition and resource-saturation alerting are configured and every enabled alert has a notification route.'
            ELSE
                  CASE WHEN @ErrorAlerts = 0 THEN N'No enabled alert covers error severities 17-25. ' ELSE N'' END
                + CASE WHEN @PerfAlerts = 0 AND @EngineEdition <> 8 THEN N'No enabled alert covers a performance/resource-saturation condition. ' ELSE N'' END
                + CASE WHEN @PerfAlerts = 0 AND @EngineEdition = 8 THEN N'Performance-condition alerts are not supported on Azure SQL Managed Instance; this requirement was relaxed. ' ELSE N'' END
                + CASE WHEN @AlertsNoResponse > 0 THEN CAST(@AlertsNoResponse AS nvarchar(10)) + N' enabled alert(s) fire without notifying anyone. ' ELSE N'' END
                + CASE WHEN @EnabledOperators = 0 THEN N'No enabled operator with a delivery address exists to receive alert notifications. ' ELSE N'' END
        END
      + CASE WHEN @AgentStatus <> N'unknown' AND @AgentStatus NOT LIKE N'Running%' AND @EnabledAlerts > 0
             THEN N'Note: the SQL Server Agent service is reported as ''' + @AgentStatus + N''', so configured alerts will not fire.'
             ELSE N'' END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;