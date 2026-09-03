-- Checklist: Long transactions avoided; batch large operations
-- Scope: SERVER
-- Scoring: 3 = no user transaction open longer than 5 minutes; 2 = longest open user transaction under 30 minutes; 1 = longest open user transaction under 120 minutes; 0 = a user transaction has been open 120 minutes or more, or the transaction DMVs could not be read

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Active transaction DMVs could not be read';
DECLARE @Open INT = 0;
DECLARE @Long INT = 0;
DECLARE @MaxMinutes INT = 0;
DECLARE @MaxLogMB DECIMAL(18, 2) = 0;
DECLARE @Offenders NVARCHAR(MAX) = '';
DECLARE @Read BIT = 0;

DECLARE @Tx TABLE (
    SessionId INT NOT NULL,
    DbName NVARCHAR(128) NOT NULL,
    OpenMinutes INT NOT NULL,
    LogMB DECIMAL(18, 2) NOT NULL);

BEGIN TRY
    INSERT INTO @Tx (SessionId, DbName, OpenMinutes, LogMB)
    SELECT st.session_id,
           MAX(ISNULL(DB_NAME(dt.database_id), 'unknown')),
           MAX(DATEDIFF(MINUTE, at.transaction_begin_time, GETDATE())),
           ISNULL(SUM(CONVERT(DECIMAL(18, 2), dt.database_transaction_log_bytes_used)), 0) / 1048576.0
    FROM sys.dm_tran_active_transactions AS at
    JOIN sys.dm_tran_session_transactions AS st ON st.transaction_id = at.transaction_id
    JOIN sys.dm_exec_sessions AS es ON es.session_id = st.session_id
    LEFT JOIN sys.dm_tran_database_transactions AS dt ON dt.transaction_id = at.transaction_id
    WHERE st.is_user_transaction = 1
      AND es.is_user_process = 1
      AND es.session_id <> @@SPID
      AND at.transaction_begin_time IS NOT NULL
    GROUP BY st.session_id;

    SET @Read = 1;
END TRY
BEGIN CATCH
    SET @Read = 0;
END CATCH;

SELECT @Open = COUNT(*),
       @Long = ISNULL(SUM(CASE WHEN OpenMinutes >= 5 THEN 1 ELSE 0 END), 0),
       @MaxMinutes = ISNULL(MAX(OpenMinutes), 0),
       @MaxLogMB = ISNULL(MAX(LogMB), 0)
FROM @Tx;

SELECT @Offenders = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX),
           CONCAT('spid ', SessionId, ' on ', DbName, ' open ', OpenMinutes, ' min holding ', LogMB, ' MB log')), '; '), 400), 'none')
FROM @Tx
WHERE OpenMinutes >= 5;

SET @Score = CASE
    WHEN @Read = 0 THEN 0
    WHEN @MaxMinutes < 5 THEN 3
    WHEN @MaxMinutes < 30 THEN 2
    WHEN @MaxMinutes < 120 THEN 1
    ELSE 0
END;

SET @Finding = CASE
    WHEN @Read = 0
        THEN 'sys.dm_tran_active_transactions could not be read; open transaction duration is unknown'
    ELSE CONCAT(
        'open user transactions = ', @Open,
        '; open 5 minutes or longer = ', @Long,
        '; longest open transaction = ', @MaxMinutes, ' minutes',
        '; largest log space held by a single transaction = ', @MaxLogMB, ' MB',
        '; long runners: ', @Offenders,
        ' (point-in-time observation of transactions open at audit time)')
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
