-- Checklist: Memory grants monitored (no excessive spills to tempdb)
-- Scope: SERVER
-- Scoring: 3 = no spills detected; 2 = < 1% of queries spill; 1 = 1-5% of queries spill; 0 = > 5% of queries spill

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No data available';

DECLARE @TotalPlans INT = 0;
DECLARE @SpillPlans INT = 0;

-- Count total plans in the cache
SELECT @TotalPlans = COUNT(*) FROM sys.dm_exec_query_stats;

IF @TotalPlans = 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'No query stats available to analyze; assuming no spills.';
END
ELSE
BEGIN
    -- Identify plans that have experienced spills by checking the XML plan for 'Warnings' 
    -- related to spills. We evaluate all plans in the cache to determine the percentage.
    SELECT @SpillPlans = COUNT(*)
    FROM sys.dm_exec_query_stats
    CROSS APPLY (
        SELECT CAST(query_plan AS NVARCHAR(MAX)) as PlanXml
    ) AS Xml
    WHERE PlanXml LIKE '%Warnings%' AND PlanXml LIKE '%spill%';

    DECLARE @SpillRate FLOAT = CAST(@SpillPlans AS FLOAT) / CAST(@TotalPlans AS FLOAT);

    IF @SpillPlans = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = 'No memory grant spills detected in the plan cache.';
    END
    ELSE IF @SpillRate < 0.01
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Low spill rate detected: ' + CAST(CAST(@SpillRate * 100 AS DECIMAL(5,2)) AS NVARCHAR(10)) + '% of queries spill.';
    END
    ELSE IF @SpillRate <= 0.05
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Moderate spill rate detected: ' + CAST(CAST(@SpillRate * 100 AS DECIMAL(5,2)) AS NVARCHAR(10)) + '% of queries spill.';
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'High spill rate detected: ' + CAST(CAST(@SpillRate * 100 AS DECIMAL(5,2)) AS NVARCHAR(10)) + '% of queries spill.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;