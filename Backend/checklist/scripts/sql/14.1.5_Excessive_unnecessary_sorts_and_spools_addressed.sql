-- Checklist: Excessive/unnecessary sorts and spools addressed
-- Scope: SERVER
-- Scoring: 0=Fail (>50 cached plans with Sort/Spool), 1=Partial Pass (11-50), 2=Mostly Pass (1-10 or empty cache). Max score capped at 2 due to proxy nature of plan cache.
DECLARE @Score INT = 2;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Count INT = 0;

SELECT @Count = COUNT(DISTINCT qs.plan_handle)
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
WHERE qp.query_plan.exist('//RelOp[@PhysicalOp="Sort" or @PhysicalOp="Spool"]') = 1;

SET @Score = CASE 
    WHEN @Count > 50 THEN 0
    WHEN @Count BETWEEN 11 AND 50 THEN 1
    WHEN @Count BETWEEN 1 AND 10 THEN 2
    ELSE 2
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score;
-- NOTE: This script provides automated evidence. Full compliance requires human review.