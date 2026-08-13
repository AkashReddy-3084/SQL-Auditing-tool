DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @MaxDurationMin INT = 0;

SELECT @MaxDurationMin = MAX(DATEDIFF(MINUTE, t.transaction_begin_time, GETDATE()))
FROM sys.dm_tran_active_transactions t
JOIN sys.dm_tran_session_transactions st ON t.transaction_id = st.transaction_id
WHERE st.session_id > 50 
  AND t.transaction_type IN (1, 2); -- 1 = Read/write, 2 = Read-only

IF @MaxDurationMin IS NULL SET @MaxDurationMin = 0;

IF @MaxDurationMin >= 60 SET @Score = 0;
ELSE IF @MaxDurationMin >= 10 SET @Score = 1;
ELSE IF @MaxDurationMin >= 1 SET @Score = 2;
ELSE SET @Score = 3;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;