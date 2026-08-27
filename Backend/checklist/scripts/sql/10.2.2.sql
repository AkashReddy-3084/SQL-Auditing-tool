-- Checklist: Query Store used to detect regressions and force plans where needed
-- Scope: DATABASE
-- Scoring: 3 = Query Store is read-write with runtime intervals and plans captured; 2 = Query Store is enabled with plans or runtime intervals; 1 = Query Store is enabled but has no captured plans or intervals; 0 = Query Store is unavailable or not enabled
-- NOTE: Automated evidence only; whether a specific regression required plan forcing requires human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Query Store evidence unavailable';
DECLARE @QueryStoreState NVARCHAR(60) = N'UNKNOWN';
DECLARE @PlanCount INT = 0;
DECLARE @ForcedPlanCount INT = 0;
DECLARE @RuntimeIntervalCount INT = 0;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT @QueryStoreState = ISNULL(MAX(actual_state_desc), N'UNKNOWN')
    FROM sys.database_query_store_options;
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

IF @ReadError = 0 AND @QueryStoreState IN (N'READ_WRITE', N'READ_ONLY')
BEGIN
    BEGIN TRY
        SELECT @PlanCount = COUNT(*) FROM sys.query_store_plan;
        SELECT @ForcedPlanCount = ISNULL(SUM(CASE WHEN is_forced_plan = 1 THEN 1 ELSE 0 END), 0)
        FROM sys.query_store_plan;
        SELECT @RuntimeIntervalCount = COUNT(*) FROM sys.query_store_runtime_stats_interval;
    END TRY
    BEGIN CATCH
        SET @ReadError = 1;
        SET @PlanCount = 0;
        SET @ForcedPlanCount = 0;
        SET @RuntimeIntervalCount = 0;
    END CATCH;
END;

SET @Score = CASE
    WHEN @ReadError = 1 OR @QueryStoreState NOT IN (N'READ_WRITE', N'READ_ONLY') THEN 0
    WHEN @QueryStoreState = N'READ_WRITE' AND @PlanCount > 0 AND @RuntimeIntervalCount > 0 THEN 3
    WHEN @PlanCount > 0 OR @RuntimeIntervalCount > 0 THEN 2
    ELSE 1
END;

SET @Finding = CONCAT(
    N'Query Store state = ', @QueryStoreState,
    N'; plans = ', @PlanCount,
    N'; forced plans = ', @ForcedPlanCount,
    N'; runtime-statistics intervals = ', @RuntimeIntervalCount,
    CASE WHEN @ReadError = 1 THEN N'; one or more Query Store sources could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
