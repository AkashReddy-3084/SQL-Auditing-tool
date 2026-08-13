-- Checklist: Secondary region/replica capacity provisioned or evaluated
-- Scope: SERVER
-- Scoring: 0=No secondary found; 1=Secondary exists but sync/capacity unknown; 2=Secondary synchronized or Geo-DR partner exists; 3=Capped at 2 due to proxy evidence requiring manual capacity validation
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @AgSecondaries INT = 0;
DECLARE @HealthySecondaries INT = 0;
DECLARE @GeoPartners INT = 0;

-- Check Always On AG secondaries (On-prem / MI)
IF SERVERPROPERTY('IsHadrEnabled') = 1
BEGIN
    BEGIN TRY
        SELECT @AgSecondaries = COUNT(*)
        FROM sys.availability_replicas ar
        JOIN sys.dm_hadr_availability_replica_states rs ON ar.group_id = rs.group_id AND ar.replica_id = rs.replica_id
        WHERE rs.role = 2;

        IF @AgSecondaries > 0
        BEGIN
            SELECT @HealthySecondaries = COUNT(*)
            FROM sys.dm_hadr_availability_replica_states
            WHERE role = 2 AND synchronization_health = 0;
        END
    END TRY
    BEGIN CATCH
        SET @AgSecondaries = 0;
        SET @HealthySecondaries = 0;
    END CATCH
END

-- Check Azure Geo-DR partners (Azure SQL DB / MI)
BEGIN TRY
    SELECT @GeoPartners = COUNT(*) FROM sys.geo_backup_partners;
END TRY
BEGIN CATCH
    SET @GeoPartners = 0;
END CATCH

-- Determine score
IF @AgSecondaries = 0 AND @GeoPartners = 0
    SET @Score = 0;
ELSE IF @HealthySecondaries = 0 AND @GeoPartners = 0
    SET @Score = 1;
ELSE IF @HealthySecondaries > 0 OR @GeoPartners > 0
    SET @Score = 2;

-- NOTE: This script provides automated evidence. Full compliance requires human review.
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;