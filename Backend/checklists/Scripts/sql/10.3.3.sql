SET NOCOUNT ON;

DECLARE @Result varchar(10) = 'Fail';
DECLARE @Score int = 1;
DECLARE @DatabaseQueried nvarchar(128) = N'msdb';
DECLARE @Finding nvarchar(max) = N'';

DECLARE @EngineEdition int = CAST(SERVERPROPERTY('EngineEdition') AS int);

IF @EngineEdition = 5
BEGIN
    SET @Score = 3;
    SET @DatabaseQueried = N'N/A';
    SET @Finding = N'Azure SQL Database does not support SQL Server Agent alerts; configure equivalent error/severity alerting in Azure Monitor or an external monitoring platform (manual verification).';
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
    SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
    RETURN;
END;

BEGIN TRY
    DECLARE @AlertTotal int = 0;
    DECLARE @EnabledAlertCount int = 0;
    DECLARE @EnabledSeverityAlertCount int = 0;
    DECLARE @EnabledErrorAlertCount int = 0;
    DECLARE @CriticalSeverityCovered int = 0;
    DECLARE @CriticalSeveritiesWithNotify int = 0;
    DECLARE @EnabledWithNotify int = 0;
    DECLARE @OperatorCount int = 0;
    DECLARE @AgentStatus nvarchar(128) = N'Unknown';
    DECLARE @SeverityList nvarchar(400) = N'';
    DECLARE @SampleAlerts nvarchar(500) = N'';

    IF OBJECT_ID(N'msdb.dbo.sysalerts', N'U') IS NULL
    BEGIN
        SET @Score = 0;
        SET @DatabaseQueried = N'msdb';
        SET @Finding = N'msdb.dbo.sysalerts is not accessible; cannot evaluate SQL Agent error/severity alert configuration.';
        SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
        SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
        RETURN;
    END;

    SELECT @AgentStatus = ISNULL(servicename + N'=' + status_desc, N'Unknown')
    FROM sys.dm_server_services
    WHERE servicename LIKE N'SQL Server Agent%';

    SELECT
        @AlertTotal = COUNT(*),
        @EnabledAlertCount = SUM(CASE WHEN a.enabled = 1 THEN 1 ELSE 0 END),
        @EnabledSeverityAlertCount = SUM(CASE WHEN a.enabled = 1 AND a.severity >= 1 AND a.message_id = 0 THEN 1 ELSE 0 END),
        @EnabledErrorAlertCount = SUM(CASE WHEN a.enabled = 1 AND a.message_id > 0 THEN 1 ELSE 0 END),
        @EnabledWithNotify = SUM(CASE
            WHEN a.enabled = 1
             AND EXISTS (
                    SELECT 1
                    FROM msdb.dbo.sysnotifications n
                    WHERE n.alert_id = a.id
                      AND (n.notification_method & 1 = 1
                           OR n.notification_method & 2 = 2
                           OR n.notification_method & 4 = 4)
                )
            THEN 1 ELSE 0 END)
    FROM msdb.dbo.sysalerts a;

    ;WITH CriticalSev AS (
        SELECT v.severity
        FROM (VALUES (19),(20),(21),(22),(23),(24),(25)) AS v(severity)
    ),
    Covered AS (
        SELECT c.severity,
               MAX(CASE WHEN a.enabled = 1 THEN 1 ELSE 0 END) AS is_enabled,
               MAX(CASE
                       WHEN a.enabled = 1
                        AND EXISTS (
                               SELECT 1
                               FROM msdb.dbo.sysnotifications n
                               WHERE n.alert_id = a.id
                                 AND (n.notification_method & 1 = 1
                                      OR n.notification_method & 2 = 2
                                      OR n.notification_method & 4 = 4)
                           )
                       THEN 1 ELSE 0 END) AS has_notify
        FROM CriticalSev c
        LEFT JOIN msdb.dbo.sysalerts a
            ON a.severity = c.severity
           AND a.message_id = 0
        GROUP BY c.severity
    )
    SELECT
        @CriticalSeverityCovered = SUM(CASE WHEN is_enabled = 1 THEN 1 ELSE 0 END),
        @CriticalSeveritiesWithNotify = SUM(CASE WHEN has_notify = 1 THEN 1 ELSE 0 END)
    FROM Covered;

    SELECT @SeverityList = STUFF((
        SELECT N',' + CAST(a.severity AS nvarchar(10))
        FROM msdb.dbo.sysalerts a
        WHERE a.enabled = 1
          AND a.severity >= 1
          AND a.message_id = 0
        GROUP BY a.severity
        ORDER BY a.severity
        FOR XML PATH(N''), TYPE
    ).value(N'.[1]', N'nvarchar(400)'), 1, 1, N'');

    SELECT @SampleAlerts = STUFF((
        SELECT TOP 8 N'; ' + LEFT(a.name, 40)
            + N'(sev=' + CAST(a.severity AS nvarchar(10))
            + N',err=' + CAST(a.message_id AS nvarchar(10))
            + N',en=' + CAST(a.enabled AS nvarchar(1)) + N')'
        FROM msdb.dbo.sysalerts a
        WHERE a.enabled = 1
          AND (a.severity >= 1 OR a.message_id > 0)
        ORDER BY CASE WHEN a.severity >= 19 THEN 0 ELSE 1 END, a.severity DESC, a.message_id
        FOR XML PATH(N''), TYPE
    ).value(N'.[1]', N'nvarchar(500)'), 1, 2, N'');

    IF OBJECT_ID(N'msdb.dbo.sysoperators', N'U') IS NOT NULL
    BEGIN
        SELECT @OperatorCount = COUNT(*)
        FROM msdb.dbo.sysoperators
        WHERE enabled = 1;
    END;

    SET @AlertTotal = ISNULL(@AlertTotal, 0);
    SET @EnabledAlertCount = ISNULL(@EnabledAlertCount, 0);
    SET @EnabledSeverityAlertCount = ISNULL(@EnabledSeverityAlertCount, 0);
    SET @EnabledErrorAlertCount = ISNULL(@EnabledErrorAlertCount, 0);
    SET @CriticalSeverityCovered = ISNULL(@CriticalSeverityCovered, 0);
    SET @CriticalSeveritiesWithNotify = ISNULL(@CriticalSeveritiesWithNotify, 0);
    SET @EnabledWithNotify = ISNULL(@EnabledWithNotify, 0);
    SET @OperatorCount = ISNULL(@OperatorCount, 0);

    IF @CriticalSeverityCovered >= 7 AND @CriticalSeveritiesWithNotify >= 7
    BEGIN
        SET @Score = 3;
        SET @Finding = N'Critical severity alerts 19-25 are enabled with notification bindings. Enabled severity alerts='
            + CAST(@EnabledSeverityAlertCount AS nvarchar(10))
            + N'; enabled error-number alerts=' + CAST(@EnabledErrorAlertCount AS nvarchar(10))
            + N'; alerts with notifications=' + CAST(@EnabledWithNotify AS nvarchar(10))
            + N'; enabled operators=' + CAST(@OperatorCount AS nvarchar(10))
            + N'; severity list=[' + ISNULL(@SeverityList, N'') + N']'
            + N'; Agent=' + ISNULL(@AgentStatus, N'Unknown') + N'.';
    END
    ELSE IF @CriticalSeverityCovered > 0 OR (@EnabledSeverityAlertCount + @EnabledErrorAlertCount) > 0
    BEGIN
        SET @Score = 2;
        SET @Finding = N'Partial error/severity alert coverage. Critical severities 19-25 covered='
            + CAST(@CriticalSeverityCovered AS nvarchar(10))
            + N'/7 (with notifications=' + CAST(@CriticalSeveritiesWithNotify AS nvarchar(10))
            + N'); enabled severity alerts=' + CAST(@EnabledSeverityAlertCount AS nvarchar(10))
            + N'; enabled error-number alerts=' + CAST(@EnabledErrorAlertCount AS nvarchar(10))
            + N'; alerts with notifications=' + CAST(@EnabledWithNotify AS nvarchar(10))
            + N'; enabled operators=' + CAST(@OperatorCount AS nvarchar(10))
            + N'; severity list=[' + ISNULL(@SeverityList, N'') + N']'
            + N'; samples=[' + ISNULL(@SampleAlerts, N'') + N']'
            + N'; Agent=' + ISNULL(@AgentStatus, N'Unknown') + N'.';
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Finding = N'No enabled SQL Agent severity or error-number alerts found. Total alerts='
            + CAST(@AlertTotal AS nvarchar(10))
            + N'; enabled operators=' + CAST(@OperatorCount AS nvarchar(10))
            + N'; Agent=' + ISNULL(@AgentStatus, N'Unknown')
            + N'. Configure Agent alerts for severity 19-25 (and key errors) with operator notifications, or an equivalent monitoring solution.';
    END
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @DatabaseQueried = N'msdb';
    SET @Finding = N'Error evaluating SQL Agent alerts: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;