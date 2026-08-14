DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @HasListener BIT = 0;
DECLARE @HasCluster BIT = 0;
DECLARE @HasTestEvidence BIT = 0;
DECLARE @HasRecentSuccess BIT = 0;

-- Check for AG Listener (requires HADR enabled)
IF SERVERPROPERTY('IsHadrEnabled') = 1
BEGIN
    IF EXISTS (SELECT 1 FROM sys.availability_group_listeners)
        SET @HasListener = 1;
END

-- Check for FCI Cluster
IF SERVERPROPERTY('IsClustered') = 1
BEGIN
    IF EXISTS (SELECT 1 FROM sys.dm_os_cluster_properties)
        SET @HasCluster = 1;
END

-- If no HA configuration at all, score is 0
IF @HasListener = 0 AND @HasCluster = 0
BEGIN
    SET @Score = 0;
END
ELSE
BEGIN
    -- Check for dedicated test job evidence in msdb
    -- Filtered to avoid false positives from generic '%test%' jobs
    IF EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobs j
        WHERE j.enabled = 1
          AND (j.name LIKE '%failover%' OR j.name LIKE '%listener%' OR j.name LIKE '%ha_test%' OR j.name LIKE '%cluster_test%')
          AND EXISTS (
              SELECT 1 FROM msdb.dbo.sysjobhistory h
              WHERE h.job_id = j.job_id
                AND h.step_id = 0
                AND h.run_status = 1
                AND h.run_date >= CAST(CONVERT(VARCHAR(8), DATEADD(DAY, -90, GETDATE()), 112) AS INT)
          )
    )
    BEGIN
        SET @HasRecentSuccess = 1;
    END

    -- Check for recent failover events in AG states (proxy evidence)
    IF @HasListener = 1 AND SERVERPROPERTY('IsHadrEnabled') = 1
    BEGIN
        IF EXISTS (
            SELECT 1 FROM sys.dm_hadr_availability_group_states
            WHERE last_failover_time IS NOT NULL
              AND last_failover_time >= DATEADD(DAY, -90, GETDATE())
        )
            SET @HasTestEvidence = 1;
    END

    -- Assign score based on evidence (aligns with checklist scoring logic)
    IF @HasRecentSuccess = 1
        SET @Score = 3;
    ELSE IF @HasTestEvidence = 1
        SET @Score = 2;
    ELSE
        SET @Score = 1;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;