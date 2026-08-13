-- Checklist: Compute tier / service tier appropriate for workload (vCore/DTU, Business Critical/General Purpose)
-- Scope: SERVER
-- Scoring: 0=Dev/Test tier, 1=Unknown/missing info, 2=Production tier detected, 3=Capped at 2 due to workload dependency
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @EngineEdition INT = CAST(ISNULL(SERVERPROPERTY('EngineEdition'), 0) AS INT);
DECLARE @ServiceObjective NVARCHAR(128);

-- Detect platform and gather tier metadata
IF @EngineEdition IN (9, 10) -- Azure SQL DB or Managed Instance
BEGIN
    SELECT TOP 1 @ServiceObjective = service_objective FROM sys.database_service_objectives;
    
    IF @ServiceObjective IS NULL 
        SET @Score = 1; -- Unknown/missing tier info
    ELSE IF @ServiceObjective IN ('Basic', 'S0') 
        SET @Score = 0; -- Dev/Test tier
    ELSE 
        SET @Score = 2; -- Production tier (covers S1-S12, P1-P15, GeneralPurpose, BusinessCritical, and future tiers)
END
ELSE -- On-Premises SQL Server
BEGIN
    IF @EngineEdition IN (2, 3) 
        SET @Score = 2; -- Standard, Enterprise
    ELSE IF @EngineEdition IN (1, 4, 5, 6) 
        SET @Score = 0; -- Personal, Express, Developer, Web
    ELSE 
        SET @Score = 1; -- Unknown/Other (e.g., Linux edition or unrecognized)
END

-- Scoring is capped at 2 per checklist requirements due to workload dependency
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;