-- Checklist: AG / cluster health and replica synchronization state actively monitored — unhealthy or not-synchronizing replicas alerted
-- Scope: SERVER
-- Scoring: 0=AGs exist but no monitoring; 1=AGs exist with partial monitoring; 2=AGs exist with full monitoring; 3=No AGs configured (N/A)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @AgCount INT = 0;
DECLARE @AlertCount INT = 0;
DECLARE @JobCount INT = 0;

-- Check if AGs exist (on-prem / MI only)
IF OBJECT_ID('sys.availability_groups') IS NOT NULL
BEGIN
    SELECT @AgCount = COUNT(*) FROM sys.availability_groups;
END

IF @AgCount = 0
BEGIN
    SET @Score = 3;
END
ELSE
BEGIN
    -- Check for SQL Agent alerts related to AG/replica health & synchronization
    IF OBJECT_ID('msdb.dbo.sysalerts') IS NOT NULL
    BEGIN
        SELECT @AlertCount = COUNT(*) 
        FROM msdb.dbo.sysalerts 
        WHERE message LIKE '%Always On%' 
           OR message LIKE '%availability group%' 
           OR message LIKE '%replica%'
           OR message LIKE '%synchronization%'
           OR message LIKE '%sync%';
    END

    -- Check for SQL Agent jobs related to AG monitoring
    IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
    BEGIN
        SELECT @JobCount = COUNT(*)
        FROM msdb.dbo.sysjobs
        WHERE name LIKE '%Always On%' 
           OR name LIKE '%AG%' 
           OR name LIKE '%Availability Group%'
           OR name LIKE '%Replica%'
           OR name LIKE '%Cluster%'
           OR name LIKE '%Synchronization%'
           OR name LIKE '%Sync%';
    END

    IF @AlertCount > 0 AND @JobCount > 0
        SET @Score = 2;
    ELSE IF @AlertCount > 0 OR @JobCount > 0
        SET @Score = 1;
    ELSE
        SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;