-- Checklist: Redundancy configured for the production database (replicas / zone redundancy)
-- Scope: SERVER
-- Scoring: 3 = Multiple replicas/Zone redundancy active; 2 = Single replica/Basic redundancy; 1 = Minimal evidence of HA; 0 = No redundancy found

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No redundancy detected';

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    -- Azure SQL Database: Check for Geo-Replication or Zone Redundancy
    -- Note: Detailed redundancy metadata is often in the Azure Portal/API, 
    -- but we can infer from the service tier and availability properties.
    DECLARE @Edition NVARCHAR(128) = CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128));
    
    IF @Edition LIKE '%Premium%' OR @Edition LIKE '%Business Critical%'
    BEGIN
        SET @Score = 3;
        SET @Finding = 'Azure SQL Database: Production tier (' + @Edition + ') typically includes built-in redundancy/zone redundancy.';
    END
    ELSE IF @Edition LIKE '%General Purpose%' OR @Edition LIKE '%Standard%'
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Azure SQL Database: Standard/GP tier provides basic redundancy.';
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Azure SQL Database: Basic tier detected; minimal redundancy.';
    END
END
ELSE
BEGIN
    -- SQL Server / Managed Instance: Check Always On Availability Groups
    DECLARE @ReplicaCount INT = 0;
    
    BEGIN TRY
        SELECT @ReplicaCount = COUNT(*) 
        FROM sys.availability_replicas;
        
        IF @ReplicaCount >= 2
        BEGIN
            SET @Score = 3;
            SET @Finding = 'Always On Availability Group configured with ' + CAST(@ReplicaCount AS NVARCHAR(10)) + ' replicas.';
        END
        ELSE IF @ReplicaCount = 1
        BEGIN
            SET @Score = 2;
            SET @Finding = 'Availability Group exists but only one replica is configured.';
        END
        ELSE
        BEGIN
            -- Check for mirroring or other HA indicators if AGs are absent
            IF EXISTS (SELECT 1 FROM sys.database_mirroring WHERE mirroring_state = 1)
            BEGIN
                SET @Score = 2;
                SET @Finding = 'Database mirroring is active.';
            END
            ELSE
            BEGIN
                SET @Score = 0;
                SET @Finding = 'No Always On replicas or mirroring detected.';
            END
        END
    END TRY
    BEGIN CATCH
        SET @Score = 0;
        SET @Finding = 'Error querying HA metadata: ' + ERROR_MESSAGE();
    END CATCH
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;