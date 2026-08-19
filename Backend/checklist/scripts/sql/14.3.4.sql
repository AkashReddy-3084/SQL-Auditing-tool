-- Checklist: Long transactions avoided; batch large operations
-- Scope: SERVER
-- Scoring: 3 = no transactions > 5 mins; 2 = transactions > 5 mins but < 30 mins; 1 = transactions > 30 mins; 0 = transactions > 1 hour or evaluation failed.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No active transactions found';

DECLARE @MaxDurationSeconds INT = 0;
DECLARE @LongestTranID VARCHAR(MAX) = '';
DECLARE @LongestTranDuration VARCHAR(MAX) = '';

-- Identify the longest running active transaction
SELECT TOP 1 
    @MaxDurationSeconds = DATEDIFF(SECOND, transaction_begin_time, GETDATE()),
    @LongestTranID = CAST(transaction_id AS VARCHAR(MAX)),
    @LongestTranDuration = CAST(DATEDIFF(SECOND, transaction_begin_time, GETDATE()) AS VARCHAR(MAX)) + ' seconds'
FROM sys.dm_tran_active_transactions
WHERE transaction_type = 2 -- XACT_USER_TRANSACTION
ORDER BY transaction_begin_time ASC;

IF @MaxDurationSeconds IS NULL
BEGIN
    SET @Score = 3;
    SET @Finding = 'No active user transactions detected';
END
ELSE
BEGIN
    IF @MaxDurationSeconds > 3600
    BEGIN
        SET @Score = 0;
        SET @Finding = 'Critical: Transaction ' + @LongestTranID + ' has been open for ' + @LongestTranDuration + ' (over 1 hour)';
    END
    ELSE IF @MaxDurationSeconds > 1800
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Warning: Transaction ' + @LongestTranID + ' has been open for ' + @LongestTranDuration + ' (over 30 mins)';
    END
    ELSE IF @MaxDurationSeconds > 300
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Notice: Transaction ' + @LongestTranID + ' has been open for ' + @LongestTranDuration + ' (over 5 mins)';
    END
    ELSE
    BEGIN
        SET @Score = 3;
        SET @Finding = 'No transactions exceeding 5 minute threshold found. Longest: ' + @LongestTranDuration;
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;