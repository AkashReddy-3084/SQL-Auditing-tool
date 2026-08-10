-- Checklist: Deployment model is deliberate and documented (SQL Server / Azure SQL MI / Azure SQL DB) with rationale
-- Scoring: 0 = No documentation metadata found; 1 = Deployment model detected but no rationale/documentation artifacts; 2 = Extended properties or metadata containing deployment/rationale keywords exist. Max score capped at 2 as full compliance requires human review of actual documentation.
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DeploymentModel NVARCHAR(50);
DECLARE @DocMetadataExists BIT = 0;

-- Detect actual deployment model
SELECT @DeploymentModel = CASE 
    WHEN SERVERPROPERTY('EngineEdition') = 1 THEN 'SQL Server On-Premises'
    WHEN SERVERPROPERTY('EngineEdition') = 5 THEN 'Azure SQL Managed Instance'
    WHEN SERVERPROPERTY('EngineEdition') = 8 THEN 'Azure SQL Database'
    ELSE 'Unknown/Other'
END;

-- Check for documentation/rationale in extended properties (proxy for deliberate documentation)
IF EXISTS (
    SELECT 1 FROM sys.extended_properties 
    WHERE name LIKE '%Deployment%' OR name LIKE '%Rationale%' OR name LIKE '%Documentation%' OR name LIKE '%Architecture%'
)
BEGIN
    SET @DocMetadataExists = 1;
END

-- Scoring logic
IF @DocMetadataExists = 1
BEGIN
    SET @Score = 2;
    SET @Result = 'Pass';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Result = 'Fail';
END

SELECT @Result AS Result, @Score AS Score;