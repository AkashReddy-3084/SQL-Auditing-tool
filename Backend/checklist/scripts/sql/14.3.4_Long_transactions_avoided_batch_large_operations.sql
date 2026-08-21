-- Checklist: Long transactions avoided; batch large operations
-- Scope: SERVER
-- Scoring: 0=Fail (long-running >300s), 1=Partial (moderate 60-300s), 2=Mostly Pass (short <60s), 3=Pass (no open transactions)

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @LongCount INT = 0;
DECLARE @ModerateCount INT = 0;
DECLARE @ShortCount INT = 0;
DECLARE @LongDetails NVARCHAR(MAX) = '';
DECLARE @ModerateDetails NVARCHAR(MAX) = '';

-- Count active user transactions by duration
SELECT 
    @LongCount = COUNT(CASE WHEN DATEDIFF(SECOND, t.transaction_begin_time, GETDATE()) > 300 THEN 1 END),
    @ModerateCount = COUNT(CASE WHEN DATEDIFF(SECOND, t.transaction_begin_time, GETDATE()) BETWEEN 60 AND 300 THEN 1 END),
    @ShortCount = COUNT(CASE WHEN DATEDIFF(SECOND, t.transaction_begin_time, GETDATE()) < 60 THEN 1 END)
FROM sys.dm_tran_active_transactions t
JOIN sys.dm_tran_session_transactions st ON t.transaction_id = st.transaction_id
JOIN sys.dm_exec_sessions s ON st.session_id = s.session_id
WHERE s.is_user_process = 1;

-- Gather evidence for long-running transactions
IF @LongCount > 0
BEGIN
    SELECT @LongDetails = STRING_AGG(
        CAST(DATEDIFF(SECOND, t.transaction_begin_time, GETDATE()) AS NVARCHAR) + 's in ' + ISNULL(DB_NAME(s.database_id), 'N/A'), 
        ', '
    )
    FROM sys.dm_tran_active_transactions t
    JOIN sys.dm_tran_session_transactions st ON t.transaction_id = st.transaction_id
    JOIN sys.dm_exec_sessions s ON st.session_id = s.session_id
    WHERE DATEDIFF(SECOND, t.transaction_begin_time, GETDATE()) > 300;
END

-- Gather evidence for moderate duration transactions
IF @ModerateCount > 0
BEGIN
    SELECT @ModerateDetails = STRING_AGG(
        CAST(DATEDIFF(SECOND, t.transaction_begin_time, GETDATE()) AS NVARCHAR) + 's in ' + ISNULL(DB_NAME(s.database_id), 'N/A'), 
        ', '
    )
    FROM sys.dm_tran_active_transactions t
    JOIN sys.dm_tran_session_transactions st ON t.transaction_id = st.transaction_id
    JOIN sys.dm_exec_sessions s ON st.session_id = s.session_id
    WHERE DATEDIFF(SECOND, t.transaction_begin_time, GETDATE()) BETWEEN 60 AND 300;
END

-- Determine score based on thresholds
SET @Score = CASE 
    WHEN @LongCount > 0 THEN 0
    WHEN @ModerateCount > 0 THEN 1
    WHEN @ShortCount > 0 THEN 2
    ELSE 3
END;

-- Construct finding with actual evidence
SET @Finding = CASE 
    WHEN @LongCount > 0 THEN 'Long-running transactions detected (>300s): ' + ISNULL(@LongDetails, 'N/A')
    WHEN @ModerateCount > 0 THEN 'Moderate duration transactions detected (60-300s): ' + ISNULL(@ModerateDetails, 'N/A')
    WHEN @ShortCount > 0 THEN 'Short open transactions detected (<60s): ' + CAST(@ShortCount AS NVARCHAR) + ' active'
    ELSE 'No open user transactions detected'
END;

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;