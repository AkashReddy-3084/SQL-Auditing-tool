-- Checklist: Right-sizing reviewed periodically (over-provisioned tiers reduced)
-- Scope: SERVER
-- Scoring: 0=No evidence; 1=Tier info available but no review process; 2=Review job exists or monitoring active; 3=Review job ran recently and utilization indicates appropriate sizing
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @JobExists BIT = 0;
DECLARE @JobRanRecently BIT = 0;
DECLARE @UtilizationAppropriate BIT = 0;
DECLARE @TierInfoExists BIT = 0;

-- Check for tier/service objective info (Azure SQL)
IF OBJECT_ID('sys.database_service_objectives') IS NOT NULL
BEGIN
    SET @TierInfoExists = 1;
    -- Check resource stats for utilization (Azure SQL DB)
    IF OBJECT_ID('sys.resource_stats') IS NOT NULL
    BEGIN
        SELECT @UtilizationAppropriate = CASE WHEN ISNULL(AVG(avg_cpu_percent), 0) < 70.0 THEN 1 ELSE 0 END
        FROM sys.resource_stats
        WHERE start_time > DATEADD(day, -7, GETUTCDATE());
    END
    -- Fallback for Azure SQL MI
    ELSE IF OBJECT_ID('sys.dm_db_resource_stats') IS NOT NULL
    BEGIN
        SELECT @UtilizationAppropriate = CASE WHEN ISNULL(AVG(avg_cpu_percent), 0) < 70.0 THEN 1 ELSE 0 END
        FROM sys.dm_db_resource_stats;
    END
END

-- Check for SQL Agent jobs related to right-sizing/tier review
IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    SELECT @JobExists = CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END
    FROM msdb.dbo.sysjobs j
    WHERE j.enabled = 1
      AND (j.name LIKE '%right%size%' OR j.name LIKE '%tier%review%' OR j.name LIKE '%cost%optim%' OR j.name LIKE '%sizing%');

    IF @JobExists = 1
    BEGIN
        SELECT @JobRanRecently = CASE WHEN MAX(jh.run_date) >= CONVERT(INT, CONVERT(CHAR(8), DATEADD(day, -30, GETDATE()), 112)) THEN 1 ELSE 0 END
        FROM msdb.dbo.sysjobs j
        JOIN msdb.dbo.sysjobhistory jh ON j.job_id = jh.job_id
        WHERE j.enabled = 1
          AND jh.step_id = 0
          AND jh.run_status = 0;
    END
END

-- Determine score based on evidence
IF @TierInfoExists = 0 AND @JobExists = 0 SET @Score = 0;
ELSE IF @JobExists = 0 SET @Score = 1;
ELSE IF @JobRanRecently = 1 AND @UtilizationAppropriate = 1 SET @Score = 3;
ELSE SET @Score = 2;

-- NOTE: This script provides automated evidence. Full compliance requires human review.
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;