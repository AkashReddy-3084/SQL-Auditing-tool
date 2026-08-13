-- Checklist: Applicable regulatory/compliance regime(s) identified and documented
-- Scope: SERVER
-- Scoring: 0=No evidence, 1=Generic policy keywords, 2=Specific regime keywords found, 3=N/A (Proxy evidence max)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

-- Check for specific regulatory keywords in server-level extended properties
IF EXISTS (
    SELECT 1 
    FROM sys.extended_properties 
    WHERE class = 0 -- Server level
      AND (
          name LIKE '%GDPR%' OR CAST(value AS NVARCHAR(MAX)) LIKE '%GDPR%' OR
          name LIKE '%HIPAA%' OR CAST(value AS NVARCHAR(MAX)) LIKE '%HIPAA%' OR
          name LIKE '%PCI%' OR CAST(value AS NVARCHAR(MAX)) LIKE '%PCI%' OR
          name LIKE '%SOX%' OR CAST(value AS NVARCHAR(MAX)) LIKE '%SOX%'
      )
)
BEGIN
    SET @Score = 2; -- Specific regime identified
END
ELSE IF EXISTS (
    SELECT 1 
    FROM sys.extended_properties 
    WHERE class = 0 -- Server level
      AND (
          name LIKE '%Regulation%' OR CAST(value AS NVARCHAR(MAX)) LIKE '%Regulation%' OR
          name LIKE '%Compliance%' OR CAST(value AS NVARCHAR(MAX)) LIKE '%Compliance%'
      )
)
BEGIN
    SET @Score = 1; -- Generic compliance mentioned
END

-- NOTE: This script provides automated evidence. Full compliance requires human review.
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;