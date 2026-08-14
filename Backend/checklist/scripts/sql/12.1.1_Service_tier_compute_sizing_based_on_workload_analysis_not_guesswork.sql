-- Checklist: Service tier / compute sizing based on workload analysis (not guesswork)
-- Scope: SERVER
-- Scoring: 0=No metrics/tier info; 1=Severe under/over utilization (<10% or >90%); 2=Moderate utilization (10-90%); 3=Optimal utilization (20-80%) with explicit tier config
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @CpuUsage DECIMAL(5,2) = 0;
DECLARE @HasTier BIT = 0;

-- Check for Azure SQL service tier
IF EXISTS (SELECT 1 FROM sys.database_service_objectives)
BEGIN
    SET @HasTier = 1;
END
ELSE
BEGIN
    -- On-prem: consider explicit max server memory configuration as "tier" proxy
    -- Default max server memory is 2147483647 MB. Explicit config will be lower.
    IF EXISTS (SELECT 1 FROM sys.configurations WHERE name = 'max server memory (MB)' AND value_in_use < 2147483647)
    BEGIN
        SET @HasTier = 1;
    END
END

-- Get average CPU usage % from resource monitor ring buffer (proxy for workload intensity)
SELECT @CpuUsage = AVG(record.value('(/Record/@CpuUsage)[1]', 'DECIMAL(5,2)'))
FROM sys.dm_os_ring_buffers
WHERE ring_buffer_type = N'RING_BUFFER_RESOURCE_MONITOR';

IF @CpuUsage IS NULL SET @CpuUsage = 0;

-- Evaluate scoring (order matters: check highest score first)
IF @CpuUsage BETWEEN 20 AND 80 AND @HasTier = 1
    SET @Score = 3;
ELSE IF @CpuUsage BETWEEN 10 AND 90
    SET @Score = 2;
ELSE IF @CpuUsage < 10 OR @CpuUsage > 90
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;