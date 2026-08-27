-- Checklist: Blocking monitored and root causes addressed
-- Scope: SERVER
-- Scoring: 3 = blocking threshold and monitoring evidence are configured; 2 = one strong monitoring indicator; 1 = partial blocking evidence; 0 = no blocking monitoring evidence
-- NOTE: Automated evidence only; root-cause resolution requires human review of incidents and workload history.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'Blocking monitoring metadata could not be evaluated';
DECLARE @Bpt INT = 0;
DECLARE @BpSessions INT = 0;
DECLARE @BlockAlerts INT = 0;

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Score = 1;
    SET @Finding = N'Azure SQL Database blocking monitoring requires platform telemetry beyond this server-level T-SQL probe';
END
ELSE
BEGIN
    BEGIN TRY
        SELECT @Bpt = ISNULL(CONVERT(INT, value_in_use), 0)
        FROM sys.configurations
        WHERE name = 'blocked process threshold (s)';

        SELECT @BpSessions = COUNT(*)
        FROM sys.server_event_sessions AS s
        JOIN sys.server_event_session_events AS e ON e.event_session_id = s.event_session_id
        WHERE e.name LIKE '%blocked_process%';

        SELECT @BlockAlerts = COUNT(*)
        FROM msdb.dbo.sysalerts
        WHERE name LIKE '%block%';

        IF @Bpt > 0 AND (@BpSessions > 0 OR @BlockAlerts > 0) SET @Score = 3;
        ELSE IF @Bpt > 0 OR @BpSessions > 0 OR @BlockAlerts > 0 SET @Score = 2;
        ELSE SET @Score = 0;

        SET @Finding = N'bpt=' + CONVERT(NVARCHAR(20), @Bpt) + N', bp_sessions=' + CONVERT(NVARCHAR(20), @BpSessions) + N', block_alerts=' + CONVERT(NVARCHAR(20), @BlockAlerts);
    END TRY
    BEGIN CATCH
        SET @Score = 1;
        SET @Finding = N'Partial blocking evidence; metadata read failed: ' + ERROR_MESSAGE();
    END CATCH;
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;