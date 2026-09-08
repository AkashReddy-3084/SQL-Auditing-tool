-- Checklist: Query Store enabled and configured appropriately
-- Scope: DATABASE
-- Scoring: 3 = Query Store enabled, capturing (capture mode <> NONE), storage limit > 100 MB, not read-only; 2 = enabled/capturing but storage limit <= 100 MB; 1 = enabled but capture mode NONE or in read-only state; 0 = Query Store not enabled

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @ActualState INT = 0;
DECLARE @CaptureMode NVARCHAR(60);
DECLARE @MaxStorageMb BIGINT = 0;
DECLARE @ReadOnlyReason INT = 0;

SET @DatabaseQueried = DB_NAME();

IF OBJECT_ID('sys.database_query_store_options') IS NOT NULL
BEGIN
    SELECT @ActualState = actual_state,
           @CaptureMode = desired_state_desc,
           @MaxStorageMb = ISNULL(max_storage_size_mb, 0),
           @ReadOnlyReason = ISNULL(readonly_reason, 0)
    FROM sys.database_query_store_options;
END

SET @Score = CASE WHEN ISNULL(@ActualState,0) = 0 THEN 0
                  WHEN @CaptureMode = 'OFF' OR ISNULL(@ReadOnlyReason,0) <> 0 THEN 1
                  WHEN ISNULL(@MaxStorageMb,0) <= 100 THEN 2
                  ELSE 3 END;
SET @Finding = CASE WHEN ISNULL(@ActualState,0) = 0 THEN 'Query Store is not enabled'
                    ELSE CONCAT('Query Store actual_state = ', @ActualState, ', desired_state = ', ISNULL(@CaptureMode,'unknown'), ', max_storage_size_mb = ', ISNULL(@MaxStorageMb,0), ', readonly_reason = ', ISNULL(@ReadOnlyReason,0)) END;
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;