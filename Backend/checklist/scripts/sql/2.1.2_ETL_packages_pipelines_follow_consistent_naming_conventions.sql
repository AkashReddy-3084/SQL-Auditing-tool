USE master;
-- Checklist: ETL packages/pipelines follow consistent naming conventions
-- Scope: SERVER
-- Scoring: 0=No ETL objects or completely random names, 1=Highly inconsistent (<50% follow pattern), 2=Mostly consistent (50-89% follow pattern), 3=Fully consistent (>=90% follow pattern)
-- NOTE: Automated naming convention validation is heuristic. Full compliance requires human review against organizational standards.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

CREATE TABLE #EtlNames (Name NVARCHAR(256));

-- Collect SSIS packages if SSISDB exists (On-prem / Azure SQL MI)
IF DB_ID('SSISDB') IS NOT NULL
BEGIN
    INSERT INTO #EtlNames
    SELECT name FROM SSISDB.catalog.packages 
    WHERE name LIKE '%ETL%' OR name LIKE '%SSIS%' OR name LIKE '%Load%' OR name LIKE '%Extract%' OR name LIKE '%Transform%' OR name LIKE '%DW%' OR name LIKE '%Data%';
END

-- Collect SQL Agent jobs likely related to ETL (On-prem / Azure SQL MI)
IF DB_ID('msdb') IS NOT NULL
BEGIN
    INSERT INTO #EtlNames
    SELECT name FROM msdb.dbo.sysjobs
    WHERE name LIKE '%ETL%' OR name LIKE '%SSIS%' OR name LIKE '%Load%' OR name LIKE '%Extract%' OR name LIKE '%Transform%' OR name LIKE '%DW%' OR name LIKE '%Data%';
END

-- Remove duplicates
SELECT DISTINCT Name INTO #DistinctNames FROM #EtlNames;

DECLARE @Total INT = (SELECT COUNT(*) FROM #DistinctNames);
DECLARE @PatternMatch INT = 0;

IF @Total > 0
BEGIN
    -- Find the most common prefix (first 3 characters)
    DECLARE @CommonPrefix NVARCHAR(3);
    SELECT TOP 1 @CommonPrefix = LEFT(Name, 3)
    FROM #DistinctNames
    GROUP BY LEFT(Name, 3)
    ORDER BY COUNT(*) DESC;

    -- Count how many names start with this prefix
    SELECT @PatternMatch = COUNT(*)
    FROM #DistinctNames
    WHERE Name LIKE @CommonPrefix + '%';

    DECLARE @Percentage DECIMAL(5,2);
    SET @Percentage = (@PatternMatch * 100.0) / @Total;

    IF @Percentage >= 90 SET @Score = 3;
    ELSE IF @Percentage >= 50 SET @Score = 2;
    ELSE SET @Score = 1; -- <50% follow pattern (Highly inconsistent)
END
ELSE
BEGIN
    SET @Score = 0; -- No ETL objects found
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #EtlNames;
DROP TABLE #DistinctNames;

SELECT @Result AS Result, @Score AS Score;