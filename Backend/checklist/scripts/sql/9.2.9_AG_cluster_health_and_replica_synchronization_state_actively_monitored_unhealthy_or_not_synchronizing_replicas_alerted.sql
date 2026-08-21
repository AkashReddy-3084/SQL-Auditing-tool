-- Checklist: AG / cluster health and replica synchronization state actively monitored — unhealthy or not-synchronizing replicas alerted
-- Scope: SERVER
-- Scoring: 3=AGs configured + monitoring/alerts + operators + replicas synchronized; 2=AGs configured + monitoring/alerts but missing operators or replicas out of sync; 1=AGs configured + no monitoring/alerts; 0=No AGs configured.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @AgCount INT = 0;
DECLARE @JobCount INT = 0;
DECLARE @AlertCount INT = 0;
DECLARE @OperatorCount INT = 0;
DECLARE @UnsyncReplicas NVARCHAR(MAX) = '';
DECLARE @MonitoringJobs NVARCHAR(MAX) = '';
DECLARE @MonitoringAlerts NVARCHAR(MAX) = '';
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = '';

IF @EngineEdition = 5
BEGIN
    SET @Score = 3;
    SET @Finding = 'Azure SQL Database: HA and replica synchronization are platform-managed. No AG/Agent monitoring required.';
END
ELSE
BEGIN
    SELECT @AgCount = COUNT(*) FROM sys.availability_groups;

    IF @AgCount = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No Availability Groups configured.';
    END
    ELSE
    BEGIN
        -- Check for monitoring jobs
        SELECT @JobCount = COUNT(*),
               @MonitoringJobs = COALESCE(STRING_AGG(name, ', ') WITHIN GROUP (ORDER BY name), 'None')
        FROM msdb.dbo.sysjobs
        WHERE name LIKE '%AG%' OR name LIKE '%AlwaysOn%' OR name LIKE '%Availability%' OR name LIKE '%Cluster%' OR name LIKE '%Replica%' OR name LIKE '%Sync%';

        -- Check for monitoring alerts (AG/WSFC message IDs or high severity)
        SELECT @AlertCount = COUNT(*),
               @MonitoringAlerts = COALESCE(STRING_AGG(CONVERT(NVARCHAR(128), message_id), ', ') WITHIN GROUP (ORDER BY message_id), 'None')
        FROM msdb.dbo.sysalerts
        WHERE (message_id BETWEEN 957 AND 1599 OR severity >= 16)
          AND enabled = 1;

        -- Check for operators
        SELECT @OperatorCount = COUNT(*) FROM msdb.dbo.sysoperators;

        -- Check replica sync state
        SELECT @UnsyncReplicas = COALESCE(
            STRING_AGG(
                ar.name + ' (' + drs.synchronization_state_desc + ')',
                ', '
            ) WITHIN GROUP (ORDER BY ar.name),
            ''
        )
        FROM sys.dm_hadr_availability_replica_states drs
        JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
        WHERE drs.role = 2 -- Secondary
          AND drs.synchronization_state_desc <> 'SYNCHRONIZED';

        -- Determine score
        IF @JobCount > 0 OR @AlertCount > 0
        BEGIN
            IF @OperatorCount > 0 AND @UnsyncReplicas = ''
                SET @Score = 3;
            ELSE
                SET @Score = 2;
        END
        ELSE
        BEGIN
            SET @Score = 1;
        END

        -- Build finding
        SET @Finding = 'AGs configured: ' + CONVERT(NVARCHAR(10), @AgCount) + '. ';
        SET @Finding = @Finding + 'Monitoring jobs: ' + @MonitoringJobs + '. ';
        SET @Finding = @Finding + 'Monitoring alerts: ' + @MonitoringAlerts + '. ';
        SET @Finding = @Finding + 'Operators: ' + CONVERT(NVARCHAR(10), @OperatorCount) + '. ';
        IF @UnsyncReplicas <> ''
            SET @Finding = @Finding + 'Unsync replicas: ' + @UnsyncReplicas + '. ';
        ELSE
            SET @Finding = @Finding + 'All replicas synchronized.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;