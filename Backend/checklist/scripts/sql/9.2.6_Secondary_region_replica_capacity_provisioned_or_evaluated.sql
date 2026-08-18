-- Checklist: Secondary region/replica capacity provisioned or evaluated
-- Scope: SERVER
-- Scoring: 0: No secondary replicas configured or all offline. 1: Secondary replicas configured but in degraded/recovering state. 2: Secondary replicas online but not fully synchronized or capacity evaluation is indirect. 3: Secondary replicas provisioned, online, and synchronized.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

SET @DatabaseQueried = 'master';

IF @EngineEdition = 5
BEGIN
    SET @Score = 3;
    SET @Finding = 'Azure SQL Database: Secondary region/replica capacity is managed by the platform and automatically provisioned for HA/DR.';
END
ELSE IF OBJECT_ID('sys.availability_replicas') IS NOT NULL
BEGIN
    DECLARE @SecondaryCount INT = 0;
    DECLARE @OnlineCount INT = 0;
    DECLARE @SyncCount INT = 0;

    SELECT 
        @SecondaryCount = COUNT(*),
        @OnlineCount = SUM(CASE WHEN ars.operational_state_desc = 'ONLINE' THEN 1 ELSE 0 END),
        @SyncCount = SUM(CASE WHEN ars.synchronization_state_desc IN ('SYNCHRONIZED', 'SYNCHRONIZING') THEN 1 ELSE 0 END)
    FROM sys.availability_replicas ar
    JOIN sys.dm_hadr_availability_replica_states ars ON ar.group_id = ars.group_id AND ar.replica_id = ars.replica_id
    WHERE ar.role_desc = 'SECONDARY';

    IF @SecondaryCount = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No secondary replicas configured for High Availability/Disaster Recovery.';
    END
    ELSE IF @OnlineCount = 0
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Secondary replicas configured but none are online. Count: ' + CAST(@SecondaryCount AS NVARCHAR(10)) + '.';
    END
    ELSE IF @SyncCount < @OnlineCount
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Secondary replicas online but not fully synchronized. Online: ' + CAST(@OnlineCount AS NVARCHAR(10)) + ', Synchronized: ' + CAST(@SyncCount AS NVARCHAR(10)) + '.';
    END
    ELSE
    BEGIN
        SET @Score = 3;
        SET @Finding = 'Secondary replicas provisioned, online, and synchronized. Count: ' + CAST(@SecondaryCount AS NVARCHAR(10)) + '.';
    END
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = 'Always On Availability Groups not configured or DMVs unavailable on this platform.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;