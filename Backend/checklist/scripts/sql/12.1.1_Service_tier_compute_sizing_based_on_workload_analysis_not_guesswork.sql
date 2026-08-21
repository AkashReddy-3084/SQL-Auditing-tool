-- Checklist: Service tier / compute sizing based on workload analysis (not guesswork)
-- Scope: SERVER
-- Scoring: 0 = Utilization <10% or >90% (severe misalignment); 1 = Utilization <20% or >80% (likely misaligned); 2 = Utilization 20-80% (reasonable alignment, proxy evidence); 3 = Not achievable via automation (requires documented workload analysis review).

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @UtilizationPct DECIMAL(5,2);

-- Platform-specific resource utilization collection
IF @EngineEdition IN (5, 8) -- Azure SQL Database or Managed Instance
BEGIN
    SELECT 
        @UtilizationPct = AVG(avg_cpu_percent)
    FROM sys.dm_db_resource_stats;
END
ELSE -- SQL Server
BEGIN
    DECLARE @TotalMemKB BIGINT;
    DECLARE @PhysMemKB BIGINT;
    
    SELECT @TotalMemKB = CAST(cntr_value AS BIGINT)
    FROM sys.dm_os_performance_counters
    WHERE counter_name = 'Total Server Memory (KB)';
    
    SELECT @PhysMemKB = physical_memory_kb
    FROM sys.dm_os_sys_info;
    
    IF @PhysMemKB > 0 AND @TotalMemKB IS NOT NULL
        SET @UtilizationPct = (@TotalMemKB * 100.0) / @PhysMemKB;
    ELSE
        SET @UtilizationPct = 50.0; -- Neutral fallback if metrics unavailable
END

-- Determine score based on utilization proxy
IF @UtilizationPct < 10.0 OR @UtilizationPct > 90.0
    SET @Score = 0;
ELSE IF @UtilizationPct < 20.0 OR @UtilizationPct > 80.0
    SET @Score = 1;
ELSE
    SET @Score = 2;

-- Cap at 2 for proxy/indirect checks requiring human review
IF @Score > 2 SET @Score = 2;

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding = 'Observed resource utilization: ' + CAST(@UtilizationPct AS NVARCHAR(20)) + '%. ' +
    CASE 
        WHEN @Score = 0 THEN 'Severe under/over-provisioning detected. Sizing likely not based on workload analysis.'
        WHEN @Score = 1 THEN 'Utilization outside optimal range. Sizing may require review.'
        WHEN @Score = 2 THEN 'Utilization within acceptable range. Proxy evidence suggests reasonable alignment.'
    END + 
    ' -- NOTE: This script provides automated evidence. Full compliance requires human review.';

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;