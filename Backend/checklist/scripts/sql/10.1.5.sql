-- Checklist: Long-running/blocking query alerting configured
-- Scope: SERVER
-- Scoring: 3 = blocked-process threshold and both alert/XE evidence are present; 2 = threshold plus one alerting mechanism, or both alerting mechanisms without threshold; 1 = one relevant artifact; 0 = no evidence
-- NOTE: Automated evidence only; external alert routing and Azure Monitor rules require human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'No long-running or blocking query alerting evidence found';
DECLARE @BlockedProcessThreshold INT = 0;
DECLARE @PerformanceAlertCount INT = 0;
DECLARE @PerformanceConditionAlertCount INT = 0;
DECLARE @ExtendedEventSessionCount INT = 0;
DECLARE @AlertNames NVARCHAR(MAX) = N'none';
DECLARE @ExtendedEventNames NVARCHAR(MAX) = N'none';

BEGIN TRY
    SELECT @BlockedProcessThreshold = ISNULL(MAX(CONVERT(INT, value_in_use)), 0)
    FROM sys.configurations
    WHERE name = N'blocked process threshold (s)';
END TRY
BEGIN CATCH
    SET @BlockedProcessThreshold = 0;
END CATCH;

BEGIN TRY
    SELECT @PerformanceAlertCount = COUNT(*)
    FROM msdb.dbo.sysalerts
    WHERE enabled = 1
      AND (name LIKE N'%block%' OR name LIKE N'%long%'
           OR name LIKE N'%slow%' OR name LIKE N'%duration%');

    SELECT @PerformanceConditionAlertCount = COUNT(*)
    FROM msdb.dbo.sysalerts
    WHERE enabled = 1
      AND performance_condition IS NOT NULL;

    SELECT @AlertNames = ISNULL(STUFF((
        SELECT N', ' + name
        FROM msdb.dbo.sysalerts
        WHERE enabled = 1
          AND (name LIKE N'%block%' OR name LIKE N'%long%'
               OR name LIKE N'%slow%' OR name LIKE N'%duration%')
        ORDER BY name
        FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N''), N'none');
END TRY
BEGIN CATCH
    SET @PerformanceAlertCount = 0;
    SET @PerformanceConditionAlertCount = 0;
    SET @AlertNames = N'unavailable';
END CATCH;

BEGIN TRY
    SELECT @ExtendedEventSessionCount = COUNT(*)
    FROM sys.server_event_sessions AS s
    INNER JOIN sys.server_event_session_events AS e
        ON e.event_session_id = s.event_session_id
    WHERE e.name LIKE N'%blocked%' OR e.name LIKE N'%long%';

    SELECT @ExtendedEventNames = ISNULL(STUFF((
        SELECT N', ' + s.name
        FROM sys.server_event_sessions AS s
        INNER JOIN sys.server_event_session_events AS e
            ON e.event_session_id = s.event_session_id
        WHERE e.name LIKE N'%blocked%' OR e.name LIKE N'%long%'
        GROUP BY s.name
        ORDER BY s.name
        FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N''), N'none');
END TRY
BEGIN CATCH
    SET @ExtendedEventSessionCount = 0;
    SET @ExtendedEventNames = N'unavailable';
END CATCH;

SET @Score = CASE
    WHEN @BlockedProcessThreshold > 0
         AND (@PerformanceAlertCount > 0 OR @PerformanceConditionAlertCount > 0)
         AND @ExtendedEventSessionCount > 0 THEN 3
    WHEN (@BlockedProcessThreshold > 0 AND (@PerformanceAlertCount > 0 OR @PerformanceConditionAlertCount > 0))
         OR (@BlockedProcessThreshold > 0 AND @ExtendedEventSessionCount > 0)
         OR ((@PerformanceAlertCount > 0 OR @PerformanceConditionAlertCount > 0) AND @ExtendedEventSessionCount > 0) THEN 2
    WHEN @BlockedProcessThreshold > 0 OR @PerformanceAlertCount > 0
         OR @PerformanceConditionAlertCount > 0 OR @ExtendedEventSessionCount > 0 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'blocked process threshold (s) = ', @BlockedProcessThreshold,
    N'; matching enabled alerts = ', @PerformanceAlertCount,
    N' [', @AlertNames, N']',
    N'; enabled performance-condition alerts = ', @PerformanceConditionAlertCount,
    N'; matching Extended Events sessions = ', @ExtendedEventSessionCount,
    N' [', @ExtendedEventNames, N']');
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;