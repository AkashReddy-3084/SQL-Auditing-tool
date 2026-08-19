-- Checklist: Excessive/unnecessary sorts and spools addressed
-- Scope: SERVER
-- Scoring: 3 = no sorts/spools in cache; 2 = < 5% of cached plans have them; 1 = 5-20% have them; 0 = > 20% have them

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No cached plans found';

DECLARE @TotalPlans INT = 0;
DECLARE @BadPlans INT = 0;

-- Temporary table to hold plan analysis
CREATE TABLE #PlanAnalysis (PlanHandle VARBINARY(64), HasIssue BIT);

INSERT INTO #PlanAnalysis (PlanHandle, HasIssue)
SELECT 
    cp.plan_handle,
    CASE 
        WHEN CAST(qp.query_plan AS XML).exist('//*, 
            local-name()="Sort" or 
            local-name()="TableSpool" or 
            local-name()="TableSpoolEager"') = 1 
        THEN 1 ELSE 0 
    END
FROM sys.dm_exec_cached_plans cp
CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) qp
WHERE cp.cachespace_usage > 0;

SELECT @TotalPlans = COUNT(*) FROM #PlanAnalysis;

IF @TotalPlans = 0
BEGIN
    SET @Score = 0;
    SET @Finding = 'No cached plans found to analyze';
END
ELSE
BEGIN
    SELECT @BadPlans = SUM(CAST(HasIssue AS INT)) FROM #PlanAnalysis;
    
    -- Scoring based on proportion
    DECLARE @Ratio FLOAT = CAST(@BadPlans AS FLOAT) / NULLIF(@TotalPlans, 0);

    IF @BadPlans = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = 'No sorts or spools found in cached plans';
    END
    ELSE IF @Ratio < 0.05
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Low incidence of sorts/spools (' + CAST(CAST(@Ratio*100 AS DECIMAL(5,2)) AS NVARCHAR(10)) + '%)';
    END
    ELSE IF @Ratio < 0.20
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Moderate incidence of sorts/spools (' + CAST(CAST(@Ratio*100 AS DECIMAL(5,2)) AS NVARCHAR(10)) + '%)';
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'High incidence of sorts/spools (' + CAST(CAST(@Ratio*100 AS DECIMAL(5,2)) AS NVARCHAR(10)) + '%)';
    END
END

DROP TABLE #PlanAnalysis;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;