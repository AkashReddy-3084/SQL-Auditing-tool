-- Checklist: Geo-replication / failover group configured for DR where required
-- Scope: SERVER
-- Scoring: 3: Failover group or geo-replication configured (secondary replica(s) detected). 2: Availability group configured but only primary replica detected (local HA). 1: AG metadata exists but replicas not accessible or state unknown. 0: No AG or failover group configured.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @AgCount INT = 0;
DECLARE @ReplicaCount INT = 0;
DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    SET @DatabaseQueried = DB_NAME();
    IF OBJECT_ID('sys.availability_groups') IS NOT NULL
    BEGIN
        SELECT @AgCount = COUNT(*) FROM sys.availability_groups;
        IF @AgCount > 0 AND OBJECT_ID('sys.availability_replicas') IS NOT NULL
        BEGIN
            SELECT @ReplicaCount = COUNT(*) FROM sys.availability_replicas;
        END
    END
END
ELSE -- SQL Server / Azure SQL MI
BEGIN
    SET @DatabaseQueried = 'master';
    IF OBJECT_ID('master.sys.availability_groups') IS NOT NULL
    BEGIN
        SELECT @AgCount = COUNT(*) FROM master.sys.availability_groups;
        IF @AgCount > 0 AND OBJECT_ID('master.sys.availability_replicas') IS NOT NULL
        BEGIN
            SELECT @ReplicaCount = COUNT(*) FROM master.sys.availability_replicas;
        END
    END
END

SET @Score = CASE
    WHEN @AgCount = 0 THEN 0
    WHEN @ReplicaCount > 1 THEN 3
    WHEN @ReplicaCount = 1 THEN 2
    ELSE 1
END;

SET @Finding = CASE
    WHEN @AgCount = 0 THEN 'No availability group or failover group configured.'
    WHEN @ReplicaCount > 1 THEN 'Failover group or geo-replication configured with ' + CAST(@ReplicaCount AS NVARCHAR(10)) + ' replica(s).'
    WHEN @ReplicaCount = 1 THEN 'Availability group configured with single replica (local HA only).'
    ELSE 'Availability group metadata detected but replica information unavailable.'
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;