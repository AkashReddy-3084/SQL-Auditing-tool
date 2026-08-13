-- Checklist: Deployment model is deliberate and documented (SQL Server / Azure SQL MI / Azure SQL DB) with rationale
-- Scope: SERVER
-- Scoring: 0 = Unable to detect deployment model; 1 = Ambiguous or unsupported deployment model detected; 2 = Valid deployment model (On-prem, Azure SQL DB, or Azure SQL MI) detected, but documentation/rationale requires human review; 3 = Not achievable via script (documentation verification requires human judgment)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @EngineEdition INT;

BEGIN TRY
    SET @EngineEdition = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
    
    IF @EngineEdition IN (1, 2, 5) -- 1=On-prem SQL Server, 2=Azure SQL DB, 5=Azure SQL Managed Instance
    BEGIN
        SET @Score = 2;
    END
    ELSE IF @EngineEdition IS NOT NULL
    BEGIN
        SET @Score = 1;
    END
END TRY
BEGIN CATCH
    SET @Score = 0;
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

-- NOTE: This script provides automated evidence. Full compliance requires human review.
SELECT @Result AS Result, @Score AS Score;