-- Checklist: Key lookups minimized via covering indexes where beneficial
-- Scope: SERVER
-- Scoring: 3: 0 key lookups in plan cache. 2: 1-5. 1: 6-20. 0: >20.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @KeyLookupCount INT = 0;

BEGIN TRY
    SELECT @KeyLookupCount = COUNT(DISTINCT qs.plan_handle)
    FROM sys.dm_exec_query_stats qs
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
    WHERE qp.query_plan.exist('//RelOp[@LogicalOp="Key Lookup"]') = 1;
END TRY
BEGIN CATCH
    SET @KeyLookupCount = 0;
END CATCH;

SET @Score = CASE
    WHEN @KeyLookupCount = 0 THEN 3
    WHEN @KeyLookupCount <= 5 THEN 2
    WHEN @KeyLookupCount <= 20 THEN 1
    ELSE 0
END;

SET @Finding = CASE
    WHEN @KeyLookupCount = 0 THEN 'No queries with Key Lookup operators found in the plan cache.'
    ELSE CAST(@KeyLookupCount AS NVARCHAR(10)) + ' distinct queries with Key Lookup operators found in the plan cache.'
END;

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;