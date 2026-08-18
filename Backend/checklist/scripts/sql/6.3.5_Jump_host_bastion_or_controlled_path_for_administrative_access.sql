-- Checklist: Jump-host/bastion or controlled path for administrative access
-- Scope: SERVER
-- Scoring: 0: Multiple diverse client IPs detected or no access restrictions visible. 1: TCP/IP enabled but no clear evidence of restricted access paths. 2: Limited connection sources or Azure firewall rules indicate controlled access; requires human verification. 3: Not achievable automatically; caps at 2.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @DistinctIPs INT;
DECLARE @AzureFirewallRules INT;
DECLARE @TcpEnabled BIT;

-- Check TCP/IP endpoint availability
SELECT @TcpEnabled = CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END
FROM sys.endpoints
WHERE type = 4;

-- Check distinct client IPs from current connections
SELECT @DistinctIPs = COUNT(DISTINCT client_net_address)
FROM sys.dm_exec_connections
WHERE client_net_address IS NOT NULL;

-- Check Azure firewall rules if applicable
SET @AzureFirewallRules = 0;
IF SERVERPROPERTY('EngineEdition') IN (5, 8)
BEGIN
    IF OBJECT_ID('sys.database_firewall_rules') IS NOT NULL
        SELECT @AzureFirewallRules = COUNT(*) FROM sys.database_firewall_rules;
    ELSE IF OBJECT_ID('sys.firewall_rules') IS NOT NULL
        SELECT @AzureFirewallRules = COUNT(*) FROM sys.firewall_rules;
END

-- Determine score based on proxy evidence
IF @TcpEnabled = 0
    SET @Score = 1;
ELSE IF @AzureFirewallRules > 0
    SET @Score = 2;
ELSE IF @DistinctIPs <= 2
    SET @Score = 2;
ELSE IF @DistinctIPs > 2
    SET @Score = 0;
ELSE
    SET @Score = 1;

-- Build finding with actual evidence
SET @Finding = 'TCP/IP Endpoint: ' + CASE WHEN @TcpEnabled = 1 THEN 'Enabled' ELSE 'Disabled' END + '; ';
SET @Finding = @Finding + 'Distinct Client IPs: ' + CAST(@DistinctIPs AS NVARCHAR(10)) + '; ';
IF @AzureFirewallRules > 0
    SET @Finding = @Finding + 'Azure Firewall Rules: ' + CAST(@AzureFirewallRules AS NVARCHAR(10)) + ' configured; ';
SET @Finding = @Finding + 'NOTE: This script provides automated evidence. Full compliance requires human review.';

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;