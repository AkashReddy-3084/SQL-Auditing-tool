SET NOCOUNT ON;

DECLARE @Result varchar(10);
DECLARE @Score int;
DECLARE @DatabaseQueried nvarchar(128);
DECLARE @Finding nvarchar(max);

DECLARE @EngineEdition int = CAST(SERVERPROPERTY('EngineEdition') AS int);
SET @DatabaseQueried = N'server';

IF @EngineEdition = 5
BEGIN
    SET @Score = 0;
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
    SET @Finding = N'Azure SQL Database detected (EngineEdition=5). SQL Agent alerts (msdb.dbo.sysalerts) are not available; resource/error alerts must be verified in Azure Monitor outside T-SQL.';
    SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
    RETURN;
END;

IF OBJECT_ID(N'msdb.dbo.sysalerts', N'U') IS NULL
BEGIN
    SET @Score = 0;
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
    SET @Finding = N'msdb.dbo.sysalerts is not available on this instance; SQL Agent alert configuration for resource saturation and errors cannot be verified.';
    SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
    RETURN;
END;

DECLARE @EnabledAlertCount int = 0;
DECLARE @ErrorAlertCount int = 0;
DECLARE @ResourceAlertCount int = 0;
DECLARE @NotifiedAlertCount int = 0;
DECLARE @SampleAlerts nvarchar(max) = N'';

;WITH AlertBase AS (
    SELECT
        a.id,
        a.name,
        a.enabled,
        a.has_notification,
        a.severity,
        a.message_id,
        a.performance_condition,
        CASE
            WHEN NULLIF(LTRIM(RTRIM(ISNULL(a.performance_condition, N''))), N'') IS NOT NULL THEN 1
            ELSE 0
        END AS IsResourceAlert,
        CASE
            WHEN ISNULL(a.severity, 0) >= 16
              OR ISNULL(a.message_id, 0) > 0
              OR LOWER(ISNULL(a.name, N'')) LIKE N'%error%'
              OR LOWER(ISNULL(a.name, N'')) LIKE N'%severity%'
              OR LOWER(ISNULL(a.name, N'')) LIKE N'%fail%'
            THEN 1
            ELSE 0
        END AS IsErrorAlert
    FROM msdb.dbo.sysalerts AS a
    WHERE a.enabled = 1
)
SELECT
    @EnabledAlertCount = COUNT(*),
    @ErrorAlertCount = SUM(IsErrorAlert),
    @ResourceAlertCount = SUM(IsResourceAlert),
    @NotifiedAlertCount = SUM(CASE WHEN has_notification > 0 THEN 1 ELSE 0 END)
FROM AlertBase;

;WITH Notified AS (
    SELECT DISTINCT n.alert_id
    FROM msdb.dbo.sysnotifications AS n
    WHERE n.notification_method > 0
)
SELECT
    @NotifiedAlertCount = CASE
        WHEN COUNT(*) > @NotifiedAlertCount THEN COUNT(*)
        ELSE @NotifiedAlertCount
    END
FROM msdb.dbo.sysalerts AS a
INNER JOIN Notified AS n ON n.alert_id = a.id
WHERE a.enabled = 1;

;WITH TopAlerts AS (
    SELECT TOP (8)
        a.name,
        a.severity,
        a.message_id,
        CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(a.performance_condition, N''))), N'') IS NOT NULL THEN N'resource' ELSE N'other' END AS alert_kind
    FROM msdb.dbo.sysalerts AS a
    WHERE a.enabled = 1
    ORDER BY
        CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(a.performance_condition, N''))), N'') IS NOT NULL THEN 0 ELSE 1 END,
        CASE WHEN ISNULL(a.severity, 0) >= 16 OR ISNULL(a.message_id, 0) > 0 THEN 0 ELSE 1 END,
        a.name
)
SELECT @SampleAlerts = STUFF((
    SELECT N'; ' + ta.name
        + N' [sev=' + CAST(ISNULL(ta.severity, 0) AS nvarchar(10))
        + N', msg=' + CAST(ISNULL(ta.message_id, 0) AS nvarchar(10))
        + N', ' + ta.alert_kind + N']'
    FROM TopAlerts AS ta
    FOR XML PATH(N''), TYPE
).value(N'.[1]', N'nvarchar(max)'), 1, 2, N'');

IF @EnabledAlertCount = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No enabled SQL Agent alerts found in msdb.dbo.sysalerts. Resource saturation and error alerting are not configured at the instance.';
END
ELSE IF @ErrorAlertCount > 0 AND @ResourceAlertCount > 0 AND @NotifiedAlertCount > 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'Enabled SQL Agent alerts cover both error/severity conditions and resource (performance-condition) alerts, with operator notification configured. Enabled alerts='
        + CAST(@EnabledAlertCount AS nvarchar(20))
        + N'; error-related=' + CAST(@ErrorAlertCount AS nvarchar(20))
        + N'; resource-related=' + CAST(@ResourceAlertCount AS nvarchar(20))
        + N'; with-notification=' + CAST(@NotifiedAlertCount AS nvarchar(20))
        + N'. Samples: ' + ISNULL(@SampleAlerts, N'n/a') + N'.';
END
ELSE
BEGIN
    SET @Score = 2;
    SET @Finding = N'Enabled SQL Agent alerts exist but coverage is incomplete for resource saturation and/or errors (or notifications are missing). Enabled alerts='
        + CAST(@EnabledAlertCount AS nvarchar(20))
        + N'; error-related=' + CAST(@ErrorAlertCount AS nvarchar(20))
        + N'; resource-related=' + CAST(@ResourceAlertCount AS nvarchar(20))
        + N'; with-notification=' + CAST(@NotifiedAlertCount AS nvarchar(20))
        + N'. Samples: ' + ISNULL(@SampleAlerts, N'n/a') + N'.';
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;