-- Checklist: AG / cluster health and replica synchronization state actively monitored - unhealthy or not-synchronizing replicas alerted
-- Scope: SERVER
-- Scoring: 3 = all database replicas HEALTHY and an AG-health alert exists (or Azure SQL DB platform-managed); 2 = healthy but no alert configured, or an alert exists but a replica is unhealthy; 1 = an unhealthy/not-synchronizing replica exists and no alert configured; 0 = no AG configured and not Azure SQL Database

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX);

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Score = 3;
    SET @Finding = 'Azure SQL Database: replication health monitoring is platform-managed';
END
ELSE
BEGIN
    DECLARE @AgCount INT = 0, @UnhealthyReplicaCount INT = 0, @TotalReplicaDbCount INT = 0, @AgAlertCount INT = 0;

    IF OBJECT_ID('sys.availability_groups') IS NOT NULL
    BEGIN
        SELECT @AgCount = COUNT(*) FROM sys.availability_groups;

        SELECT @TotalReplicaDbCount = COUNT(*) FROM sys.dm_hadr_database_replica_states;

        SELECT @UnhealthyReplicaCount = COUNT(*)
        FROM sys.dm_hadr_database_replica_states
        WHERE synchronization_health_desc <> 'HEALTHY';
    END

    IF OBJECT_ID('msdb.dbo.sysalerts') IS NOT NULL
        SELECT @AgAlertCount = COUNT(*) FROM msdb.dbo.sysalerts
        WHERE (name LIKE '%availability%' OR name LIKE '%AG%' OR message_id IN (1480, 35262, 35264))
          AND has_notification > 0;

    SET @Score = CASE WHEN ISNULL(@AgCount,0) = 0 THEN 0
                      WHEN ISNULL(@UnhealthyReplicaCount,0) = 0 AND ISNULL(@AgAlertCount,0) > 0 THEN 3
                      WHEN ISNULL(@UnhealthyReplicaCount,0) = 0 OR ISNULL(@AgAlertCount,0) > 0 THEN 2
                      ELSE 1 END;
    SET @Finding = CASE WHEN ISNULL(@AgCount,0) = 0 THEN 'No Availability Group configured'
                        ELSE CONCAT('Database replicas total = ', ISNULL(@TotalReplicaDbCount,0), ', unhealthy/not-synchronizing = ', ISNULL(@UnhealthyReplicaCount,0), ', AG-health alerts configured = ', ISNULL(@AgAlertCount,0)) END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;