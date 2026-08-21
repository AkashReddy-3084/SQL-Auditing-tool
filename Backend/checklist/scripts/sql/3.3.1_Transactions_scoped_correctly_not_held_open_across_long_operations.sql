-- Checklist: Transactions scoped correctly (not held open across long operations)
-- Scope: SERVER
-- Scoring: 0: Multiple long-running transactions (>5 min). 1: One long-running transaction. 2: Active transactions but all <5 min. 3: No active open transactions.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @LongThreshold INT = 5; -- minutes

CREATE TABLE #LongTxns (
    DbName NVARCHAR(128),
    SessionId INT,
    ElapsedMin INT,
    TxnName NVARCHAR(128),
    Command NVARCHAR(128),
    SqlText NVARCHAR(4000)
);

INSERT INTO #LongTxns
SELECT 
    COALESCE(DB_NAME(r.database_id), 'N/A') AS DbName,
    s.session_id,
    DATEDIFF(MINUTE, t.start_time, GETDATE()) AS ElapsedMin,
    t.name AS TxnName,
    ISNULL(r.command, 'Idle/Waiting') AS Command,
    ISNULL(st.text, 'No active request') AS SqlText
FROM sys.dm_tran_active_transactions t
JOIN sys.dm_tran_session_transactions stx ON t.transaction_id = stx.transaction_id
JOIN sys.dm_exec_sessions s ON stx.session_id = s.session_id
LEFT JOIN sys.dm_exec_requests r ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) st
WHERE DATEDIFF(MINUTE, t.start_time, GETDATE()) >= @LongThreshold
  AND s.is_user_process = 1;

DECLARE @LongCount INT = (SELECT COUNT(*) FROM #LongTxns);
DECLARE @TotalActive INT = (
    SELECT COUNT(*) 
    FROM sys.dm_tran_active_transactions t
    JOIN sys.dm_tran_session_transactions stx ON t.transaction_id = stx.transaction_id
    JOIN sys.dm_exec_sessions s ON stx.session_id = s.session_id
    WHERE s.is_user_process = 1
);

IF @LongCount > 1
    SET @Score = 0;
ELSE IF @LongCount = 1
    SET @Score = 1;
ELSE IF @TotalActive > 0
    SET @Score = 2;
ELSE
    SET @Score = 3;

SET @DatabaseQueried = 'master';

IF @Score <= 1
BEGIN
    SET @Finding = STRING_AGG(
        DbName + ' (Session: ' + CAST(SessionId AS NVARCHAR(10)) + ', Elapsed: ' + CAST(ElapsedMin AS NVARCHAR(10)) + ' min, Command: ' + Command + ')',
        '; '
    ) FROM #LongTxns;
END
ELSE IF @Score = 2
BEGIN
    SET @Finding = 'Active transactions detected but all within acceptable duration (<5 min).';
END
ELSE
BEGIN
    SET @Finding = 'No active open transactions found.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #LongTxns;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;