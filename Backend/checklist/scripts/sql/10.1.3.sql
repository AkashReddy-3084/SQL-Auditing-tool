-- Checklist: Resource utilization trended over time
-- Scope: DATABASE
-- Scoring: 3 = Query Store enabled with a retention window > 0 days; 2 = reserved; 1 = Query Store enabled but retention window is 0; 0 = Query Store is not enabled
-- NOTE: Automated evidence only; server-level resource trending (CPU/memory/DTU history) via an external monitoring tool is not independently verified. Full compliance requires human review.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @QueryStoreEnabled INT = 0;
DECLARE @RetentionDays INT = 0;

SET @DatabaseQueried = DB_NAME();

IF OBJECT_ID('sys.database_query_store_options') IS NOT NULL
BEGIN
    SELECT @QueryStoreEnabled = CASE WHEN actual_state = 1 THEN 1 ELSE 0 END,
           @RetentionDays = ISNULL(stale_query_threshold_days, 0)
    FROM sys.database_query_store_options;
END

SET @Score = CASE WHEN ISNULL(@QueryStoreEnabled,0) = 0 THEN 0
                  WHEN ISNULL(@RetentionDays,0) > 0 THEN 3
                  ELSE 1 END;
SET @Finding = CASE WHEN ISNULL(@QueryStoreEnabled,0) = 0 THEN 'Query Store is not enabled - no historical resource-utilization trending mechanism found'
                    ELSE CONCAT('Query Store enabled; retention window (days) = ', ISNULL(@RetentionDays,0)) END;
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;