-- Checklist: AG / cluster health and replica synchronization state actively monitored - unhealthy or not-synchronizing replicas alerted
-- Scope: SERVER
-- Scoring: 3 = AGs exist, no unhealthy databases are reported, and AG alerts plus enabled alerts are present; 2 = AGs exist with no unhealthy databases or relevant alerts; 1 = AGs exist but unhealthy databases are reported without relevant alerts; 0 = no AG or evidence is unavailable
-- NOTE: Automated evidence confirms metadata and alert definitions; alert routing and operational response require human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'AG health and alert evidence unavailable';
DECLARE @AvailabilityGroupCount INT = 0;
DECLARE @UnhealthyDatabaseCount INT = 0;
DECLARE @AgAlertCount INT = 0;
DECLARE @EnabledAlertCount INT = 0;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT @AvailabilityGroupCount = COUNT(*)
    FROM sys.availability_groups;

    SELECT @UnhealthyDatabaseCount = COUNT(*)
    FROM sys.dm_hadr_database_replica_states
    WHERE synchronization_health_desc <> N'HEALTHY';

    SELECT @AgAlertCount = COUNT(*)
    FROM msdb.dbo.sysalerts
    WHERE name LIKE N'%availab%'
       OR name LIKE N'%replica%'
       OR name LIKE N'%sync%';

    SELECT @EnabledAlertCount = COUNT(*)
    FROM msdb.dbo.sysalerts
    WHERE enabled = 1;
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

SET @Score = CASE
    WHEN @ReadError = 1 OR @AvailabilityGroupCount = 0 THEN 0
    WHEN @UnhealthyDatabaseCount = 0 AND @AgAlertCount > 0 AND @EnabledAlertCount > 0 THEN 3
    WHEN @UnhealthyDatabaseCount = 0 OR @AgAlertCount > 0 OR @EnabledAlertCount > 0 THEN 2
    WHEN @UnhealthyDatabaseCount > 0 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'Availability Groups = ', @AvailabilityGroupCount,
    N'; unhealthy database replicas = ', @UnhealthyDatabaseCount,
    N'; AG-related alerts = ', @AgAlertCount,
    N'; enabled alerts = ', @EnabledAlertCount,
    CASE WHEN @ReadError = 1 THEN N'; one or more AG health sources could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
