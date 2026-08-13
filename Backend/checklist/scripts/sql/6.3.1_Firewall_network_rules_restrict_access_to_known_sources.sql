-- Checklist: Firewall / network rules restrict access to known sources
-- Scope: SERVER
-- Scoring: 0=No evidence/empty connections, 1=Weak proxy (many IPs/broad rules), 2=Strong proxy (limited IPs), 3=Fully verified (Azure explicit rules)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @IsAzure BIT = 0;
DECLARE @DistinctIPs INT = 0;
DECLARE @FirewallRulesCount INT = 0;
DECLARE @HasBroadRule BIT = 0;

-- Detect Azure SQL DB / MI
IF OBJECT_ID('sys.database_service_objectives') IS NOT NULL OR OBJECT_ID('sys.firewall_rules') IS NOT NULL
    SET @IsAzure = 1;

IF @IsAzure = 1
BEGIN
    -- Azure SQL DB / MI firewall check
    IF OBJECT_ID('sys.firewall_rules') IS NOT NULL
    BEGIN
        SELECT @FirewallRulesCount = COUNT(*), @HasBroadRule = MAX(CASE WHEN start_ip_address = '0.0.0.0' THEN 1 ELSE 0 END)
        FROM sys.firewall_rules;
    END

    -- Scoring per checklist: 0=No evidence, 1=Weak (broad rules), 3=Fully verified (explicit rules)
    IF @FirewallRulesCount = 0 SET @Score = 0;
    ELSE IF @HasBroadRule = 1 SET @Score = 1;
    ELSE SET @Score = 3;
END
ELSE
BEGIN
    -- On-prem proxy: check active connection sources
    BEGIN TRY
        SELECT @DistinctIPs = COUNT(DISTINCT client_net_address)
        FROM sys.dm_exec_connections
        WHERE client_net_address IS NOT NULL;
    END TRY
    BEGIN CATCH
        SET @DistinctIPs = 0;
    END CATCH

    -- Scoring per checklist: 0=No evidence/empty, 1=Weak (many IPs), 2=Strong (limited IPs)
    IF @DistinctIPs = 0 SET @Score = 0;
    ELSE IF @DistinctIPs BETWEEN 1 AND 5 SET @Score = 2;
    ELSE SET @Score = 1; -- Covers 6+ IPs (weak/many)
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;