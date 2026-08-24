-- Checklist: TLS enforced for data in transit (Encrypt=true; minimum TLS version set)
-- Scope: SERVER
-- Scoring: 3 = 100% of active connections report encrypt_option = TRUE; 2 = 50-99%; 1 = under 50%; 0 = no active connections found
-- NOTE: Automated evidence only; reflects currently active sessions, not the minimum TLS version policy. Full compliance requires human review.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX);
DECLARE @TotalConnections INT, @EncryptedConnections INT;

SELECT @TotalConnections = COUNT(*) FROM sys.dm_exec_connections;
SELECT @EncryptedConnections = COUNT(*) FROM sys.dm_exec_connections WHERE encrypt_option = 'TRUE';

SET @Score = CASE WHEN ISNULL(@TotalConnections,0) = 0 THEN 0
                  WHEN @EncryptedConnections = @TotalConnections THEN 3
                  WHEN (CAST(ISNULL(@EncryptedConnections,0) AS DECIMAL(9,4)) / NULLIF(@TotalConnections,0)) >= 0.50 THEN 2
                  ELSE 1 END;
SET @Finding = CASE WHEN ISNULL(@TotalConnections,0) = 0 THEN 'No active connections found'
                    ELSE CONCAT('Active connections = ', @TotalConnections, ', encrypted (encrypt_option=TRUE) = ', ISNULL(@EncryptedConnections,0)) END;
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;