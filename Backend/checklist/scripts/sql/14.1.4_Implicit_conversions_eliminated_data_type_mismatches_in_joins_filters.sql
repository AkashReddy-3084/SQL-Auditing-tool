-- Checklist: Implicit conversions eliminated (data-type mismatches in joins/filters)
-- Scope: SERVER
-- Scoring: 0 = No cached plans or >5 implicit conversions found; 1 = 1-5 implicit conversions found; 2 = Zero implicit conversions found. NOTE: Max score capped at 2 as cached plans are proxy evidence for overall codebase compliance.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @TotalPlans INT = 0;
DECLARE @ImplicitCount INT = 0;

BEGIN TRY
    SELECT @TotalPlans = COUNT(*) FROM sys.dm_exec_query_stats;

    SELECT @ImplicitCount = COUNT(DISTINCT qs.sql_handle)
    FROM sys.dm_exec_query_stats qs
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
    WHERE qp.query_plan.exist('//Convert[@Implicit="1"]') = 1;
END TRY
BEGIN CATCH
    SET @TotalPlans = 0;
    SET @ImplicitCount = 0;
END CATCH;

IF @TotalPlans = 0
    SET @Score = 0;
ELSE IF @ImplicitCount = 0
    SET @Score = 2;
ELSE IF @ImplicitCount <= 5
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;