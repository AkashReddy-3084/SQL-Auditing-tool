-- Checklist: No broad "allow Azure services" / 0.0.0.0 firewall rules
-- Scope: SERVER
-- Scoring: 3 = no broad rules; 2 = only "Allow Azure Services" enabled; 1 = 0.0.0.0 rule exists; 0 = multiple broad rules or unable to query.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Setting could not be read';

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @DatabaseQueried = DB_NAME();
    
    DECLARE @BroadRuleCount INT = 0;
    DECLARE @AzureServicesEnabled BIT = 0;
    DECLARE @AnyIPRuleExists BIT = 0;
    DECLARE @RuleDetails NVARCHAR(MAX) = '';

    BEGIN TRY
        -- In Azure SQL DB sys.firewall_rules:
        -- 'Allow Azure services' is represented as 0.0.0.0 to 0.0.0.0
        -- A broad 'Any IP' rule is typically 0.0.0.0 to 255.255.255.255
        SELECT 
            @BroadRuleCount = COUNT(*),
            @AzureServicesEnabled = MAX(CASE WHEN start_ip_address = '0.0.0.0' AND end_ip_address = '0.0.0.0' THEN 1 ELSE 0 END),
            @AnyIPRuleExists = MAX(CASE WHEN start_ip_address = '0.0.0.0' AND end_ip_address = '255.255.255.255' THEN 1 ELSE 0 END),
            @RuleDetails = STRING_AGG(CAST(name AS NVARCHAR(MAX)) + ' (' + start_ip_address + '-' + end_ip_address + ')', ', ')
        FROM sys.firewall_rules
        WHERE (start_ip_address = '0.0.0.0' AND end_ip_address = '0.0.0.0')
           OR (start_ip_address = '0.0.0.0' AND end_ip_address = '255.255.255.255');
    END TRY
    BEGIN CATCH
        SET @Score = 0;
        SET @Finding = 'Error querying sys.firewall_rules: ' + ERROR_MESSAGE();
    END CATCH

    IF @Score <> 0 OR @BroadRuleCount IS NOT NULL
    BEGIN
        IF @BroadRuleCount = 0
        BEGIN
            SET @Score = 3;
            SET @Finding = 'No broad firewall rules found';
        END
        ELSE IF @BroadRuleCount = 1 AND @AzureServicesEnabled = 1 AND @AnyIPRuleExists = 0
        BEGIN
            SET @Score = 2;
            SET @Finding = 'Only "Allow Azure services" rule is enabled';
        END
        ELSE IF @AnyIPRuleExists = 1 AND @BroadRuleCount = 1
        BEGIN
            SET @Score = 1;
            SET @Finding = 'Broad 0.0.0.0/0 firewall rule exists: ' + ISNULL(@RuleDetails, 'Unknown');
        END
        ELSE
        BEGIN
            SET @Score = 0;
            SET @Finding = 'Multiple broad firewall rules found: ' + ISNULL(@RuleDetails, 'Unknown');
        END
    END
END
ELSE
BEGIN
    -- For SQL Server / MI, firewall is handled at the NSG/OS level, not inside the engine
    SET @Score = 3;
    SET @Finding = 'Platform managed: Firewall rules are managed at the network/OS level, not via T-SQL';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;