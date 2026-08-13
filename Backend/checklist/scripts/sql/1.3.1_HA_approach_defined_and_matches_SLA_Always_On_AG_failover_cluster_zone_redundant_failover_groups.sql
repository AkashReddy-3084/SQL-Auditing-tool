-- Checklist: HA approach defined and matches SLA (Always On AG / failover cluster / zone-redundant / failover groups)
-- Scope: SERVER
-- Scoring: 0=No HA detected, 1=Failover Cluster only, 2=Always On AG or Azure Zone Redundant/Failover Group, 3=AG with synchronous commit or Azure Zone Redundant + Failover Group
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @IsClustered BIT = ISNULL(CAST(SERVERPROPERTY('IsClustered') AS BIT), 0);
DECLARE @IsHadrEnabled BIT = ISNULL(CAST(SERVERPROPERTY('IsHadrEnabled') AS BIT), 0);
DECLARE @AgCount INT = 0;
DECLARE @SyncAgCount INT = 0;
DECLARE @AzureZoneRedundant BIT = 0;
DECLARE @AzureFailoverGroup BIT = 0;

-- Check Always On AG (On-Prem / MI)
IF @IsHadrEnabled = 1
BEGIN
    SELECT @AgCount = COUNT(*) FROM sys.availability_groups;
    IF OBJECT_ID('sys.dm_hadr_availability_group_states') IS NOT NULL
    BEGIN
        SELECT @SyncAgCount = COUNT(*) 
        FROM sys.availability_groups ag
        JOIN sys.dm_hadr_availability_group_states ags ON ag.group_id = ags.group_id
        WHERE ags.synchronous_commit = 1;
    END
END

-- Check Azure Zone Redundancy (Azure SQL DB)
IF OBJECT_ID('sys.database_service_objectives') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.database_service_objectives WHERE zone_redundant = 1)
        SET @AzureZoneRedundant = 1;
END

-- Check Azure Failover Groups (Azure SQL DB)
IF OBJECT_ID('sys.failover_groups') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.failover_groups)
        SET @AzureFailoverGroup = 1;
END

-- Scoring Logic (Fixed precedence: evaluate highest scores first)
IF @SyncAgCount > 0 OR (@AzureZoneRedundant = 1 AND @AzureFailoverGroup = 1)
    SET @Score = 3;
ELSE IF @AgCount > 0 OR @AzureZoneRedundant = 1 OR @AzureFailoverGroup = 1
    SET @Score = 2;
ELSE IF @IsClustered = 1
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
-- NOTE: This script provides automated evidence. Full compliance requires human review.
SELECT @Result AS Result, @Score AS Score;