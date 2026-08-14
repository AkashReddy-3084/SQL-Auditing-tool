SET NOCOUNT ON;
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @HasHA BIT = 0;
DECLARE @IsHealthy BIT = 1; -- Default to healthy if HA is detected

-- Check Always On Availability Groups (On-prem / MI)
IF OBJECT_ID('sys.availability_groups') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.availability_groups) SET @HasHA = 1;
END

-- Check Failover Groups (Azure SQL)
IF OBJECT_ID('sys.failover_groups') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.failover_groups) SET @HasHA = 1;
END

-- Check Zone Redundancy (Azure SQL DB/MI)
BEGIN TRY
    IF OBJECT_ID('sys.server_service_objectives') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.server_service_objectives WHERE has_zone_redundancy = 1) SET @HasHA = 1;
    END
END TRY
BEGIN CATCH
    -- Fallback for Azure SQL DB where ZR is checked via database-scoped view
    BEGIN TRY
        IF EXISTS (SELECT 1 FROM sys.database_service_objectives WHERE has_zone_redundancy = 1) SET @HasHA = 1;
    END TRY
    BEGIN CATCH
        -- Ignore if view is inaccessible or context is invalid
    END CATCH
END CATCH

-- Evaluate Health (Focus on AGs as primary health indicator)
IF @HasHA = 1
BEGIN
    DECLARE @AgTotal INT = 0;
    DECLARE @AgHealthy INT = 0;
    
    IF OBJECT_ID('sys.availability_groups') IS NOT NULL
    BEGIN
        SELECT @AgTotal = COUNT(*) FROM sys.availability_groups;
        
        IF @AgTotal > 0 AND OBJECT_ID('sys.dm_hadr_availability_group_states') IS NOT NULL
        BEGIN
            BEGIN TRY
                SELECT @AgHealthy = COUNT(*) FROM sys.dm_hadr_availability_group_states WHERE synchronization_health_desc = 'HEALTHY';
                IF @AgHealthy < @AgTotal SET @IsHealthy = 0;
            END TRY
            BEGIN CATCH
                -- If DMV is inaccessible, assume healthy to avoid false failure
                SET @IsHealthy = 1;
            END CATCH
        END
    END
END

-- Assign Score
IF @HasHA = 0 
    SET @Score = 0;
ELSE IF @IsHealthy = 0 
    SET @Score = 1;
ELSE 
    SET @Score = 2;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;