-- Checklist: Deadlocks captured (Extended Events) and resolved
-- Scope: SERVER
-- Scoring: 3 = deadlock monitoring and system_health evidence are active; 2 = one monitoring indicator is active; 1 = deadlock evidence exists without active monitoring; 0 = no evidence
-- NOTE: Automated evidence only; resolution of captured deadlocks requires human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'Deadlock monitoring metadata could not be evaluated';
DECLARE @DeadlockSessions INT = 0;
DECLARE @HealthRunning INT = 0;
DECLARE @Deadlocks BIGINT = 0;
DECLARE @ProbeError NVARCHAR(4000) = N'';

BEGIN TRY
    SELECT @DeadlockSessions = COUNT(*)
    FROM sys.server_event_sessions AS s
    JOIN sys.server_event_session_events AS e ON e.event_session_id = s.event_session_id
    WHERE e.name LIKE '%deadlock%';
END TRY
BEGIN CATCH SET @ProbeError = ERROR_MESSAGE(); END CATCH;

BEGIN TRY
    SELECT @HealthRunning = COUNT(*) FROM sys.dm_xe_sessions WHERE name = 'system_health';
END TRY
BEGIN CATCH IF @ProbeError = N'' SET @ProbeError = ERROR_MESSAGE(); END CATCH;

BEGIN TRY
    SELECT @Deadlocks = ISNULL(SUM(CONVERT(BIGINT, cntr_value)), 0)
    FROM sys.dm_os_performance_counters
    WHERE counter_name LIKE 'Number of Deadlocks/sec%' AND instance_name = '_Total';
END TRY
BEGIN CATCH IF @ProbeError = N'' SET @ProbeError = ERROR_MESSAGE(); END CATCH;

IF @DeadlockSessions > 0 AND @HealthRunning > 0
BEGIN SET @Score = 3; SET @Finding = N'Deadlock capture is configured and system_health is running: dl_sessions=' + CONVERT(NVARCHAR(20), @DeadlockSessions) + N', health_running=' + CONVERT(NVARCHAR(20), @HealthRunning) + N', deadlocks=' + CONVERT(NVARCHAR(30), @Deadlocks); END
ELSE IF @DeadlockSessions > 0 OR @HealthRunning > 0
BEGIN SET @Score = 2; SET @Finding = N'Partial deadlock monitoring evidence found: dl_sessions=' + CONVERT(NVARCHAR(20), @DeadlockSessions) + N', health_running=' + CONVERT(NVARCHAR(20), @HealthRunning) + N', deadlocks=' + CONVERT(NVARCHAR(30), @Deadlocks); END
ELSE IF @Deadlocks > 0
BEGIN SET @Score = 1; SET @Finding = N'Deadlock counter evidence exists without an active capture session: dl_sessions=0, health_running=0, deadlocks=' + CONVERT(NVARCHAR(30), @Deadlocks); END
ELSE
BEGIN SET @Score = 0; SET @Finding = N'No active deadlock monitoring or deadlock counter evidence found: dl_sessions=0, health_running=0, deadlocks=0'; END

IF @ProbeError <> N'' SET @Finding = @Finding + N'; probe_warning=' + @ProbeError;
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;