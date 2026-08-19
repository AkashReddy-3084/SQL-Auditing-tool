-- Checklist: Deployment model is deliberate and documented (SQL Server / Azure SQL MI / Azure SQL DB) with rationale
-- Scope: SERVER
-- Scoring: 0=Fail (unable to detect platform), 1=Partial Pass (ambiguous detection), 2=Pass (platform detected, documentation requires human review), 3=Not achievable automatically

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT;
DECLARE @PlatformName NVARCHAR(128);

SET @EngineEdition = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

SET @PlatformName = CASE 
    WHEN @EngineEdition = 5 THEN 'Azure SQL Database'
    WHEN @EngineEdition = 8 THEN 'Azure SQL Managed Instance'
    WHEN @EngineEdition IN (1, 2, 3, 6) THEN 'SQL Server'
    ELSE 'Unknown'
END;

SET @Score = CASE 
    WHEN @PlatformName = 'Unknown' THEN 0
    WHEN @PlatformName IS NOT NULL THEN 2
    ELSE 1
END;

SET @Finding = 'Detected deployment model: ' + @PlatformName + ' (EngineEdition: ' + CAST(@EngineEdition AS NVARCHAR(10)) + ').';

-- NOTE: This script provides automated evidence. Full compliance requires human review.

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;