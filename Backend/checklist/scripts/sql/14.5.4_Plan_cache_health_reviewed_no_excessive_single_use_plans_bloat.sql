-- Checklist: Plan cache health reviewed (no excessive single-use plans / bloat)
-- Scope: SERVER
-- Scoring: 0 = >50% single-use or >4GB memory; 1 = 30-50% single-use or 2-4GB memory; 2 = 10-30% single-use or 1-2GB memory; 3 = <10% single-use and <1GB memory
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @SingleUsePlans BIGINT = 0;
DECLARE @TotalPlans BIGINT = 0;
DECLARE @SingleUsePct FLOAT = 0.0;
DECLARE @PlanCacheMB FLOAT = 0.0;
DECLARE @EngineEdition INT = CAST(ISNULL(SERVERPROPERTY('EngineEdition'), 1) AS INT);

-- Get plan cache memory usage (available on all platforms)
SELECT @PlanCacheMB = ISNULL(SUM(pages_kb), 0) / 1024.0
FROM sys.dm_os_memory_clerks
WHERE type IN ('CACHESTORE_OBJCP', 'CACHESTORE_SQLCP');

-- Get single-use vs total plans (On-prem / MI only)
IF @EngineEdition IN (1, 2, 3, 6)
BEGIN
    SELECT 
        @SingleUsePlans = SUM(CASE WHEN cp.usecounts = 1 THEN 1 ELSE 0 END),
        @TotalPlans = COUNT(*)
    FROM sys.dm_exec_cached_plans cp;

    IF @TotalPlans > 0
        SET @SingleUsePct = (@SingleUsePlans * 100.0) / @TotalPlans;
    ELSE
        SET @SingleUsePct = 0.0;
END
ELSE
BEGIN
    -- Azure SQL DB: single-use plan DMV not available, rely on memory or set neutral
    SET @SingleUsePct = 10.0;
END

-- Calculate independent scores for each metric based on checklist thresholds
DECLARE @ScorePct INT = 3;
DECLARE @ScoreMem INT = 3;

IF @SingleUsePct > 50.0 SET @ScorePct = 0;
ELSE IF @SingleUsePct > 30.0 SET @ScorePct = 1;
ELSE IF @SingleUsePct > 10.0 SET @ScorePct = 2;

IF @PlanCacheMB > 4096.0 SET @ScoreMem = 0;
ELSE IF @PlanCacheMB > 2048.0 SET @ScoreMem = 1;
ELSE IF @PlanCacheMB > 1024.0 SET @ScoreMem = 2;

-- Final score is the minimum (worst-case) of the two independent scores to satisfy the "or" condition
SET @Score = CASE WHEN @ScorePct < @ScoreMem THEN @ScorePct ELSE @ScoreMem END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;