-- Checklist: No broad "allow Azure services" / 0.0.0.0 firewall rules
-- Scope: SERVER
-- Scoring: 0 = Broad rules found (0.0.0.0 or 'Allow Azure services'); 1 = On-premises SQL Server or Azure SQL MI (firewall rules not queryable via T-SQL, requires manual OS/network review); 2 = No broad rules found, but firewall rules exist; 3 = Fully compliant (no broad rules found in Azure SQL DB)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @BroadRuleCount INT = 0;
DECLARE @TotalRuleCount INT = 0;

IF OBJECT_ID('sys.firewall_rules') IS NOT NULL
BEGIN
    SELECT @TotalRuleCount = COUNT(*)
    FROM sys.firewall_rules;
    
    SELECT @BroadRuleCount = COUNT(*)
    FROM sys.firewall_rules
    WHERE start_ip_address = '0.0.0.0'
       OR end_ip_address = '255.255.255.255'
       OR name = 'Allow Azure services';
       
    IF @BroadRuleCount > 0
        SET @Score = 0;
    ELSE IF @TotalRuleCount > 0
        SET @Score = 2;
    ELSE
        SET @Score = 3;
END
ELSE
BEGIN
    SET @Score = 1;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;