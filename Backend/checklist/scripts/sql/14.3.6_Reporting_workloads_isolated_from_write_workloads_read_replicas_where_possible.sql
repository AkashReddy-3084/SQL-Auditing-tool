-- Checklist: Reporting workloads isolated from write workloads (read replicas) where possible
-- Scope: SERVER
-- Scoring: 0=No evidence, 1=Read-only DBs only, 2=AG readable secondaries detected, 3=Readable secondaries with routing URLs configured
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @ReadableSecondaries INT = 0;
DECLARE @RoutingUrls INT = 0;
DECLARE @ReadOnlyDBs INT = 0;

-- Check for Always On Readable Secondaries (On-Prem & MI)
IF OBJECT_ID('master.sys.availability_replicas') IS NOT NULL
BEGIN
    SELECT @ReadableSecondaries = COUNT(*)
    FROM master.sys.availability_replicas ar
    INNER JOIN master.sys.dm_hadr_availability_replica_states rs ON ar.replica_id = rs.replica_id
    WHERE rs.is_read_only_secondary = 1;

    SELECT @RoutingUrls = COUNT(*)
    FROM master.sys.availability_replicas
    WHERE read_only_routing_url IS NOT NULL AND LTRIM(RTRIM(read_only_routing_url)) <> '';
END

-- Check for read-only user databases (proxy evidence for reporting isolation)
SELECT @ReadOnlyDBs = COUNT(*)
FROM master.sys.databases
WHERE database_id > 4 AND state = 0 AND is_read_only = 1;

-- Scoring logic
IF @ReadableSecondaries > 0 AND @RoutingUrls > 0
    SET @Score = 3;
ELSE IF @ReadableSecondaries > 0
    SET @Score = 2;
ELSE IF @ReadOnlyDBs > 0
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;