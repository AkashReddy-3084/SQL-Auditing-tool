-- Checklist: Excessive/unnecessary sorts and spools addressed
-- Scope: SERVER
-- Scoring: 3 = no sort, spool, or spill plans in the sampled cache; 2 = under 10% affected plans; 1 = affected plans present; 0 = no readable plans
-- NOTE: Automated evidence only; determining whether an operator is necessary requires query and workload review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'Cached query plans could not be evaluated';
DECLARE @Plans INT = 0;
DECLARE @SortPlans INT = 0;
DECLARE @SpoolPlans INT = 0;
DECLARE @SpillPlans INT = 0;

BEGIN TRY
    WITH p AS
    (
        SELECT TOP (200) CAST(qp.query_plan AS NVARCHAR(MAX)) AS xp
        FROM sys.dm_exec_cached_plans AS cp
        CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) AS qp
        WHERE cp.cacheobjtype = 'Compiled Plan' AND qp.query_plan IS NOT NULL
        ORDER BY cp.usecounts DESC
    )
    SELECT @Plans = COUNT(*),
           @SortPlans = ISNULL(SUM(CASE WHEN xp LIKE '%PhysicalOp="Sort"%' THEN 1 ELSE 0 END), 0),
           @SpoolPlans = ISNULL(SUM(CASE WHEN xp LIKE '%Spool%' THEN 1 ELSE 0 END), 0),
           @SpillPlans = ISNULL(SUM(CASE WHEN xp LIKE '%SpillToTempDb%' THEN 1 ELSE 0 END), 0)
    FROM p;

    IF @Plans = 0 SET @Score = 0;
    ELSE IF @SortPlans = 0 AND @SpoolPlans = 0 AND @SpillPlans = 0 SET @Score = 3;
    ELSE IF CONVERT(DECIMAL(9, 4), @SortPlans + @SpoolPlans + @SpillPlans) / NULLIF(@Plans, 0) < 0.10 SET @Score = 2;
    ELSE SET @Score = 1;

    SET @Finding = N'plans=' + CONVERT(NVARCHAR(20), @Plans) + N', sort_plans=' + CONVERT(NVARCHAR(20), @SortPlans) + N', spool_plans=' + CONVERT(NVARCHAR(20), @SpoolPlans) + N', spill_plans=' + CONVERT(NVARCHAR(20), @SpillPlans);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read cached query plans: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;