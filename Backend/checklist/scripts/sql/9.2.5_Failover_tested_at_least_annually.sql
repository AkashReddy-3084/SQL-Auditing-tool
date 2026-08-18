-- Checklist: Failover tested at least annually
-- Scope: SERVER
-- Scoring: 0=No HA/DR configured; 1=HA/DR partially configured or degraded; 2=HA/DR fully configured but test history unverified; 3=Not achievable automatically (requires manual log/process review)
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @HaDrTypes NVARCHAR(MAX) = '';

-- Check for Always On Availability Groups
IF SERVERPROPERTY('IsHadrEnabled') = 1 AND OBJECT_ID('sys.dm_hadr_availability_replica_states') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.dm_hadr_availability_replica_states WHERE role = 2)
        SET @HaDrTypes = @HaDrTypes + 'AlwaysOn AG, ';
END

-- Check for Failover Cluster
IF SERVERPROPERTY('IsClustered') = 1
    SET @HaDrTypes = @HaDrTypes + 'Failover Cluster, ';

-- Check for Log Shipping
IF OBJECT_ID('msdb.dbo.log_shipping_primary_databases') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM msdb.dbo.log_shipping_primary_databases)
        SET @HaDrTypes = @HaDrTypes + 'Log Shipping, ';
END

-- Clean up trailing comma/space
IF LEN(@HaDrTypes) > 0
    SET @HaDrTypes = LEFT(@HaDrTypes, LEN(@HaDrTypes) - 2);

IF @HaDrTypes = ''
BEGIN
    SET @Score = 0;
    SET @Finding = 'No High Availability or Disaster Recovery mechanisms detected.';
END
ELSE
BEGIN
    SET @Score = 2;
    SET @Finding = 'HA/DR mechanisms configured: ' + @HaDrTypes + '. Automated verification of annual failover testing is not possible; manual review of test logs/documentation is required.';
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;