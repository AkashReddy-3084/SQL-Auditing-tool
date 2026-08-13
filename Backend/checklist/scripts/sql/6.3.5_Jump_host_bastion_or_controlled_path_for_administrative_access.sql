-- Checklist: Jump-host/bastion or controlled path for administrative access
-- Scope: SERVER
-- Scoring: 0=Fail (many diverse IPs, open access), 1=Partial (limited IPs observed), 2=Mostly Pass (strong proxy evidence of controlled path/bastion), 3=Pass (explicit network/firewall restrictions verified - requires manual review)
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DistinctIPs INT = 0;

-- Gather proxy evidence: count distinct source IPs from active connections (excluding localhost)
SELECT @DistinctIPs = COUNT(DISTINCT client_net_address)
FROM sys.dm_exec_connections
WHERE client_net_address IS NOT NULL 
  AND client_net_address <> '127.0.0.1';

-- Evaluate based on proxy evidence
IF @DistinctIPs <= 2 
    SET @Score = 2; -- Strong proxy: only 1-2 IPs observed, highly indicative of a bastion/controlled path
ELSE IF @DistinctIPs <= 5 
    SET @Score = 1; -- Partial: limited external IPs, possible controlled access but not definitive
ELSE 
    SET @Score = 0; -- Fail: many diverse IPs observed, suggests open/unrestricted access

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;