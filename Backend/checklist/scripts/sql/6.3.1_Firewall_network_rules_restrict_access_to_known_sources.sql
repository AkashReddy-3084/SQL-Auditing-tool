-- Checklist: Firewall / network rules restrict access to known sources
-- Scope: SERVER
-- Scoring: 0=No rules/open access; 1=Endpoints bound to 0.0.0.0 or unexpected connections; 2=Rules exist but broad ranges (Azure) or specific endpoint bindings but OS firewall unverified (On-prem); 3=Explicit rules restrict access to known sources without broad ranges.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

IF @EngineEdition IN (5, 8) -- Azure SQL Database or Azure SQL Managed Instance
BEGIN
    DECLARE @RuleCount INT = (SELECT COUNT(*) FROM sys.firewall_rules);
    DECLARE @BroadRules INT = (
        SELECT COUNT(*) FROM sys.firewall_rules 
        WHERE start_ip_address IN ('0.0.0.0', '::') 
           OR end_ip_address IN ('255.255.255.255', 'ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff')
    );

    IF @RuleCount = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No firewall rules configured. Instance is open to all sources.';
    END
    ELSE IF @BroadRules > 0
    BEGIN
        SET @Score = 2;
        SET @Finding = CAST(@RuleCount AS NVARCHAR) + ' firewall rules found. ' + CAST(@BroadRules AS NVARCHAR) + ' rule(s) allow overly broad access (e.g., 0.0.0.0).';
    END
    ELSE
    BEGIN
        SET @Score = 3;
        SET @Finding = CAST(@RuleCount AS NVARCHAR) + ' firewall rules configured. No overly broad ranges detected.';
    END
END
ELSE -- On-premises SQL Server
BEGIN
    -- Proxy evidence: endpoint bindings and active connections
    DECLARE @OpenEndpoints INT = (
        SELECT COUNT(*) FROM sys.endpoints 
        WHERE type = 4 AND state = 0 AND address = '0.0.0.0'
    );
    DECLARE @BoundEndpoints INT = (
        SELECT COUNT(*) FROM sys.endpoints 
        WHERE type = 4 AND state = 0 AND address <> '0.0.0.0'
    );
    DECLARE @ActiveConnectionIPs INT = (
        SELECT COUNT(DISTINCT client_net_address) FROM sys.dm_exec_connections 
        WHERE client_net_address IS NOT NULL
    );

    IF @OpenEndpoints > 0
    BEGIN
        SET @Score = 1;
        SET @Finding = 'SQL Server endpoints bound to 0.0.0.0 (all interfaces). OS firewall rules cannot be verified via T-SQL. ' + CAST(@ActiveConnectionIPs AS NVARCHAR) + ' unique active connection IPs detected.';
    END
    ELSE IF @BoundEndpoints > 0
    BEGIN
        SET @Score = 2;
        SET @Finding = 'SQL Server endpoints bound to specific IPs. OS firewall rules cannot be verified via T-SQL. ' + CAST(@ActiveConnectionIPs AS NVARCHAR) + ' unique active connection IPs detected.';
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No active T-SQL endpoints found. Network access status unknown.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;