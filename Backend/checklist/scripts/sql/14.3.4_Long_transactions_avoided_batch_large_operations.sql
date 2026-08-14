DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @MaxTxDuration INT = 0;
DECLARE @BlockingCount INT = 0;
DECLARE @RemoteQueryTimeout INT = 600;
DECLARE @CostThreshold INT = 5;

-- Check active transaction durations (On-prem / MI)
IF EXISTS (SELECT 1 FROM sys.dm_tran_active_transactions)
BEGIN
    SELECT @MaxTxDuration = MAX(DATEDIFF(SECOND, last_start_time, GETDATE()))
    FROM sys.dm_tran_active_transactions
    WHERE transaction_type = 1 AND last_start_time IS NOT NULL;
END
ELSE
BEGIN
    -- Fallback for Azure SQL DB
    SELECT @MaxTxDuration = MAX(DATEDIFF(SECOND, start_time, GETDATE()))
    FROM sys.dm_exec_requests
    WHERE open_transaction_count > 0;
END

-- Check blocking chains (exclude system blockers 0 and -2)
SELECT @BlockingCount = COUNT(*)
FROM sys.dm_os_waiting_tasks
WHERE blocking_session_id > 0;

-- Check server configurations (On-prem / MI)
IF EXISTS (SELECT 1 FROM master.sys.configurations WHERE name = 'cost threshold for parallelism')
BEGIN
    SELECT @RemoteQueryTimeout = TRY_CAST(value AS INT)
    FROM master.sys.configurations
    WHERE name = 'remote query timeout (s)';

    SELECT @CostThreshold = TRY_CAST(value AS INT)
    FROM master.sys.configurations
    WHERE name = 'cost threshold for parallelism';
END

-- Scoring logic
IF @MaxTxDuration > 300 OR @BlockingCount > 3
    SET @Score = 0;
ELSE IF @MaxTxDuration > 60 OR (@RemoteQueryTimeout = 600 AND @CostThreshold = 5)
    SET @Score = 1;
ELSE IF @MaxTxDuration <= 60 AND (@RemoteQueryTimeout <> 600 OR @CostThreshold <> 5)
    SET @Score = 2;
ELSE IF @MaxTxDuration = 0 AND @BlockingCount = 0 AND @RemoteQueryTimeout <> 600 AND @CostThreshold <> 5
    SET @Score = 3;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;