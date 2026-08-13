-- Checklist: Resource Governor used where workload isolation is required (where supported)
-- Scope: SERVER
-- Scoring: 0=Disabled, 1=Enabled/No Custom Groups, 2=Enabled/Custom Groups, 3=Enabled/Custom Groups & Pools (or Not Supported)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

-- Check if Resource Governor is supported on this platform (e.g., missing in Azure SQL DB or Standard Edition)
IF OBJECT_ID('sys.resource_governor_configuration') IS NOT NULL
BEGIN
    -- Check if Resource Governor is enabled
    IF EXISTS (SELECT 1 FROM sys.resource_governor_configuration WHERE is_enabled = 1)
    BEGIN
        -- Count custom workload groups (exclude the built-in 'default' group)
        DECLARE @CustomGroupCount INT;
        SELECT @CustomGroupCount = COUNT(*) FROM sys.resource_governor_workload_groups
        WHERE name <> 'default';

        IF @CustomGroupCount > 0
        BEGIN
            -- Count custom resource pools (exclude built-in 'default' and 'internal' pools)
            DECLARE @CustomPoolCount INT;
            SELECT @CustomPoolCount = COUNT(*) FROM sys.resource_governor_resource_pools
            WHERE name NOT IN ('default', 'internal');

            IF @CustomPoolCount > 0
                SET @Score = 3; -- Strong evidence of deliberate isolation strategy
            ELSE
                SET @Score = 2; -- Evidence of isolation configuration
        END
        ELSE
        BEGIN
            SET @Score = 1; -- Enabled but no isolation configured
        END
    END
    ELSE
    BEGIN
        SET @Score = 0; -- Feature exists but is disabled
    END
END
ELSE
BEGIN
    -- Feature not supported on this edition/platform (e.g. Azure SQL DB, Standard Edition)
    -- Checklist requirement is "where supported", so this is a Pass.
    SET @Score = 3;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;