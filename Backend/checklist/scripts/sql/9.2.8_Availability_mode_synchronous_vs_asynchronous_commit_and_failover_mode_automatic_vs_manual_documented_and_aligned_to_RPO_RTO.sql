DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @AgCount INT = 0;
DECLARE @TotalReplicas INT = 0;
DECLARE @HealthyReplicas INT = 0;
DECLARE @ConfiguredReplicas INT = 0;
DECLARE @DocCount INT = 0;

-- Check for Always On Availability Groups
SELECT @AgCount = COUNT(*) FROM sys.availability_groups;

IF @AgCount > 0
BEGIN
    -- Evaluate replica health and explicit mode configuration
    SELECT 
        @TotalReplicas = COUNT(*),
        @HealthyReplicas = SUM(CASE WHEN ars.connected_state = 2 THEN 1 ELSE 0 END),
        @ConfiguredReplicas = SUM(CASE WHEN ar.failover_mode IS NOT NULL AND ar.synchronous_commit_allowed IS NOT NULL THEN 1 ELSE 0 END)
    FROM sys.availability_replicas ar
    INNER JOIN sys.dm_hadr_availability_replica_states ars 
        ON ar.group_id = ars.group_id AND ar.replica_id = ars.replica_id;

    IF @TotalReplicas > 0 AND @HealthyReplicas = @TotalReplicas AND @ConfiguredReplicas = @TotalReplicas
    BEGIN
        SET @Score = 2;
        
        -- Check for documentation (RPO/RTO alignment) via extended properties
        -- class_id 106 represents Availability Groups
        SELECT @DocCount = COUNT(*)
        FROM sys.extended_properties ep
        WHERE ep.class_id = 106 
          AND (ep.name LIKE '%RPO%' OR ep.name LIKE '%RTO%' OR ep.value LIKE '%RPO%' OR ep.value LIKE '%RTO%');
            
        IF @DocCount > 0 SET @Score = 3;
    END
    ELSE
    BEGIN
        SET @Score = 1;
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;