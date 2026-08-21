-- Checklist: Transactions scoped correctly (not held open across long operations)
-- Scope: SERVER
-- Scoring: 3 = no active transactions; 2 = transactions open < 5 mins; 1 = transactions open 5-60 mins; 0 = transactions open > 60 mins

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX);

DECLARE @MaxDurationMinutes INT = NULL;

-- Identify the longest running active transaction
SELECT TOP 1 
    @MaxDurationMinutes = DATEDIFF(MINUTE, transaction_begin_time, GETDATE())
FROM sys.dm_tran_active_transactions
WHERE transaction_state = 2 -- Active
ORDER BY transaction_begin_time ASC;

IF @MaxDurationMinutes IS NULL
BEGIN
    SET @Score = 3;
    SET @Finding = 'No active transactions found';
END
ELSE
BEGIN
    IF @MaxDurationMinutes < 5
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Longest active transaction duration: ' + CAST(@MaxDurationMinutes AS NVARCHAR(10)) + ' minutes';
    END
    ELSE IF @MaxDurationMinutes < 60
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Long active transaction detected: ' + CAST(@MaxDurationMinutes AS NVARCHAR(10)) + ' minutes';
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'Critical: Transaction held open for ' + CAST(@MaxDurationMinutes AS NVARCHAR(10)) + ' minutes';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;