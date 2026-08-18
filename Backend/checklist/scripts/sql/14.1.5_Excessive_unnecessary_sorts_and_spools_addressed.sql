-- Checklist: Excessive/unnecessary sorts and spools addressed
-- Scope: SERVER
-- Scoring: 3: <=5 plans with Sort/Spool and max execution count <1000. 2: <=20 plans and max execution count <10000. 1: <=50 plans. 0: >50 plans or any plan with execution count >=10000.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @SortSpoolCount INT = 0;
DECLARE @MaxExecCount BIGINT = 0;

CREATE TABLE #SortSpoolPlans (
    ObjectName NVARCHAR(256),
    ExecutionCount BIGINT
);

BEGIN TRY
    INSERT INTO #SortSpoolPlans (ObjectName, ExecutionCount)
    SELECT TOP 100
        ISNULL(OBJECT_NAME(st.objectid, st.dbid), 'Adhoc'),
        qs.execution_count
    FROM sys.dm_exec_query_stats qs
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
    WHERE qp.query_plan.exist('//RelOp[contains(@PhysicalOp, "Sort") or contains(@PhysicalOp, "Spool")]') = 1
    ORDER BY qs.execution_count DESC;
END TRY
BEGIN CATCH
    INSERT INTO #SortSpoolPlans (ObjectName, ExecutionCount)
    VALUES ('Permission denied or DMV unavailable', 0);
END TRY

SELECT @SortSpoolCount = COUNT(*), @MaxExecCount = ISNULL(MAX(ExecutionCount), 0) FROM #SortSpoolPlans;

SELECT @Finding = STRING_AGG(PlanInfo, ', ')
FROM (
    SELECT TOP 5 ObjectName + ' (Exec: ' + CAST(ExecutionCount AS NVARCHAR) + ')' AS PlanInfo
    FROM #SortSpoolPlans
    ORDER BY ExecutionCount DESC
) t;

IF @SortSpoolCount = 0 
    SET @Finding = 'No cached execution plans with Sort or Spool operators found.';

IF @SortSpoolCount <= 5 AND @MaxExecCount < 1000
    SET @Score = 3;
ELSE IF @SortSpoolCount <= 20 AND @MaxExecCount < 10000
    SET @Score = 2;
ELSE IF @SortSpoolCount <= 50
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;

DROP TABLE #SortSpoolPlans;