-- Checklist: Alert thresholds tuned to avoid fatigue
-- Scope: SERVER
-- Scoring: 3 = enabled alerts have threshold conditions and response throttling; 2 = partial threshold/throttling evidence; 1 = enabled alerts exist without tuning indicators; 0 = no enabled alerts
-- NOTE: Automated evidence only; confirm thresholds are appropriate for the workload.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'SQL Agent alert metadata could not be evaluated';
DECLARE @Alerts INT = 0;
DECLARE @EnabledAlerts INT = 0;
DECLARE @ThrottledAlerts INT = 0;
DECLARE @ThresholdAlerts INT = 0;
DECLARE @TotalFires INT = 0;

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Score = 1;
    SET @Finding = N'Azure SQL Database does not host SQL Agent alerts';
END
ELSE
BEGIN
    BEGIN TRY
        SELECT @Alerts = COUNT(*),
               @EnabledAlerts = ISNULL(SUM(CASE WHEN enabled = 1 THEN 1 ELSE 0 END), 0),
               @ThrottledAlerts = ISNULL(SUM(CASE WHEN enabled = 1 AND delay_between_responses > 0 THEN 1 ELSE 0 END), 0),
               @ThresholdAlerts = ISNULL(SUM(CASE WHEN enabled = 1 AND performance_condition IS NOT NULL THEN 1 ELSE 0 END), 0),
               @TotalFires = ISNULL(SUM(occurrence_count), 0)
        FROM msdb.dbo.sysalerts;

        IF @EnabledAlerts = 0 SET @Score = 0;
        ELSE IF @ThrottledAlerts = @EnabledAlerts AND @ThresholdAlerts = @EnabledAlerts SET @Score = 3;
        ELSE IF @ThrottledAlerts > 0 OR @ThresholdAlerts > 0 SET @Score = 2;
        ELSE SET @Score = 1;

        SET @Finding = N'alerts=' + CONVERT(NVARCHAR(20), @Alerts) + N', enabled_alerts=' + CONVERT(NVARCHAR(20), @EnabledAlerts) + N', throttled_alerts=' + CONVERT(NVARCHAR(20), @ThrottledAlerts) + N', threshold_alerts=' + CONVERT(NVARCHAR(20), @ThresholdAlerts) + N', total_fires=' + CONVERT(NVARCHAR(20), @TotalFires);
    END TRY
    BEGIN CATCH
        SET @Score = 0;
        SET @Finding = N'Unable to read SQL Agent alert metadata: ' + ERROR_MESSAGE();
    END CATCH;
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;