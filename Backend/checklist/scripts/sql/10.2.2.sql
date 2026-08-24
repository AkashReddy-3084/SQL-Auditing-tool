-- Checklist: Query Store used to detect regressions and force plans where needed
-- Scope: DATABASE
-- Scoring: 3 = Query Store enabled and at least one forced plan found; 2 = reserved; 1 = Query Store enabled but no forced plans; 0 = Query Store is not enabled
-- NOTE: Automated evidence only; the absence of a forced plan may simply mean no regression has occurred, not that the practice is unused. Full compliance requires human review.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @ActualState INT = 0;
DECLARE @ForcedPlanCount INT = 0;

SET @DatabaseQueried = DB_NAME();

IF OBJECT_ID('sys.database_query_store_options') IS NOT NULL
    SELECT @ActualState = actual_state FROM sys.database_query_store_options;

IF OBJECT_ID('sys.query_store_plan') IS NOT NULL
    SELECT @ForcedPlanCount = COUNT(*) FROM sys.query_store_plan WHERE is_forced_plan = 1;

SET @Score = CASE WHEN ISNULL(@ActualState,0) = 0 THEN 0
                  WHEN ISNULL(@ForcedPlanCount,0) > 0 THEN 3
                  ELSE 1 END;
SET @Finding = CASE WHEN ISNULL(@ActualState,0) = 0 THEN 'Query Store is not enabled'
                    ELSE CONCAT('Query Store enabled; forced plans currently in effect = ', ISNULL(@ForcedPlanCount,0)) END;
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;