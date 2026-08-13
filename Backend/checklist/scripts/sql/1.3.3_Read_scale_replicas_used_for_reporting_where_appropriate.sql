-- Checklist: Read-scale replicas used for reporting where appropriate
-- Scope: SERVER
-- Scoring: 0=No AGs configured, 1=AGs exist but no read routing enabled, 2=Read routing configured, 3=Read routing configured + active ReadOnly connections detected
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @AgCount INT = 0;
DECLARE @ReadRoutingConfigured INT = 0;
DECLARE @ReadOnlyConnections INT = 0;

IF OBJECT_ID('sys.availability_groups') IS NOT NULL
BEGIN
    SELECT @AgCount = COUNT(*) FROM sys.availability_groups;

    IF @AgCount > 0
    BEGIN
        SELECT @ReadRoutingConfigured = COUNT(*)
        FROM sys.availability_replicas ar
        JOIN sys.dm_hadr_availability_replica_states rs ON ar.group_id = rs.group_id AND ar.replica_id = rs.replica_id
        WHERE rs.role = 2 -- Secondary replica
          AND (ar.read_only_routing_url IS NOT NULL OR rs.is_read_compatible = 1);

        SELECT @ReadOnlyConnections = COUNT(*)
        FROM sys.dm_exec_connections
        WHERE application_intent = 'ReadOnly';
    END
END

IF @AgCount = 0
    SET @Score = 0;
ELSE IF @ReadRoutingConfigured = 0
    SET @Score = 1;
ELSE IF @ReadOnlyConnections > 0
    SET @Score = 3;
ELSE
    SET @Score = 2;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;
-- NOTE: This script provides automated evidence. Full compliance requires human review to confirm reporting workloads are appropriately routed.