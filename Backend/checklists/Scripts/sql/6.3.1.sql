-- Checklist: Firewall / network rules restrict access to known sources
-- Scope: SERVER
-- Scoring: 3 = Azure SQL DB firewall rules exist with no overly-broad (0.0.0.0-255.255.255.255) rule; 2 = platform is not Azure SQL DB (OS/network firewall not observable via T-SQL); 1 = an overly-broad firewall rule is present; 0 = Azure SQL DB with no firewall rules defined
-- NOTE: Automated evidence only; on-premises network/OS firewall configuration cannot be observed from a SQL connection. Full compliance requires human review.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX);

IF SERVERPROPERTY('EngineEdition') = 5 AND OBJECT_ID('sys.firewall_rules') IS NOT NULL
BEGIN
    DECLARE @TotalRules INT, @BroadRuleCount INT;

    SELECT @TotalRules = COUNT(*) FROM sys.firewall_rules;
    SELECT @BroadRuleCount = COUNT(*) FROM sys.firewall_rules
    WHERE start_ip_address = '0.0.0.0' AND end_ip_address = '255.255.255.255';

    SET @Score = CASE WHEN ISNULL(@TotalRules,0) = 0 THEN 0
                      WHEN ISNULL(@BroadRuleCount,0) > 0 THEN 1
                      ELSE 3 END;
    SET @Finding = CASE WHEN ISNULL(@TotalRules,0) = 0 THEN 'Azure SQL Database has no firewall rules defined'
                        ELSE CONCAT('Firewall rules defined = ', @TotalRules, ', overly-broad (all-IP) rules = ', ISNULL(@BroadRuleCount,0)) END;
END
ELSE
BEGIN
    SET @Score = 2;
    SET @Finding = 'OS/network-level firewall configuration is not observable via a SQL Server connection on this platform; treated as platform-managed. Full compliance requires human review of network security controls.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;