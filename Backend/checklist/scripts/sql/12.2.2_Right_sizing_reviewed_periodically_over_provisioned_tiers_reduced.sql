-- Checklist: Right-sizing reviewed periodically (over-provisioned tiers reduced)
-- Scope: SERVER
-- Scoring: 
-- 3: Azure SQL DB/MI with CPU utilization between 20-80% (optimal right-sizing).
-- 2: Azure SQL DB/MI with CPU 10-20% or 80-90%, or SQL Server Standard/Enterprise edition (proxy evidence).
-- 1: Azure SQL DB/MI with CPU <10% or >90% (over/under-provisioned), or SQL Server Express/Developer.
-- 0: No resource data available or extreme mismatch.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @AvgCpu DECIMAL(5,2);
DECLARE @CurrentTier NVARCHAR(128);
DECLARE @DbName NVARCHAR(128) = DB_NAME();

IF @EngineEdition IN (5, 8)
BEGIN
    SET @DatabaseQueried = @DbName;
    
    SELECT @CurrentTier = service_objective FROM sys.database_service_objectives;
    
    IF @EngineEdition = 5
    BEGIN
        SELECT @AvgCpu = AVG(avg_cpu_percent) FROM sys.dm_db_resource_stats;
    END
    ELSE
    BEGIN
        SELECT @AvgCpu = AVG(avg_cpu_percent) FROM sys.server_resource_stats;
    END

    IF @AvgCpu IS NULL
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No resource utilization data available. Unable to verify right-sizing.';
    END
    ELSE IF @AvgCpu BETWEEN 20.0 AND 80.0
    BEGIN
        SET @Score = 3;
        SET @Finding = 'Right-sizing verified. Current tier: ' + ISNULL(@CurrentTier, 'Unknown') + '. Average CPU utilization: ' + CAST(@AvgCpu AS NVARCHAR(10)) + '% (Optimal range 20-80%).'
    END
    ELSE IF @AvgCpu BETWEEN 10.0 AND 20.0 OR @AvgCpu BETWEEN 80.0 AND 90.0
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Right-sizing partially verified. Current tier: ' + ISNULL(@CurrentTier, 'Unknown') + '. Average CPU utilization: ' + CAST(@AvgCpu AS NVARCHAR(10)) + '%. Consider adjusting tier for optimal cost-performance.'
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Potential over/under-provisioning detected. Current tier: ' + ISNULL(@CurrentTier, 'Unknown') + '. Average CPU utilization: ' + CAST(@AvgCpu AS NVARCHAR(10)) + '%. Review tier alignment with workload.'
    END
END
ELSE
BEGIN
    SET @DatabaseQueried = 'master';
    DECLARE @Edition NVARCHAR(128) = CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128));
    
    IF @Edition LIKE '%Standard%' OR @Edition LIKE '%Enterprise%'
    BEGIN
        SET @Score = 2;
        SET @Finding = 'On-premises SQL Server detected. Edition: ' + @Edition + '. Tier right-sizing is a cloud-specific concept. Proxy evaluation based on edition indicates acceptable configuration.'
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Finding = 'On-premises SQL Server detected. Edition: ' + @Edition + '. Tier right-sizing is a cloud-specific concept. Limited proxy evidence available.'
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;