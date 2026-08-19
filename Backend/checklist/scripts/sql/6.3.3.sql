-- Checklist: Public network access disabled or tightly restricted (Azure SQL)
-- Scope: SERVER
-- Scoring: 3 = No public rules/Azure services allowed; 2 = Restricted rules present; 1 = Wide open rules present; 0 = Unable to determine

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Unable to determine network access status';

IF SERVERPROPERTY('EngineEdition') <> 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Non-Azure SQL Database: Public network access is managed by the host OS/Network firewall, not the SQL engine.';
END
ELSE
BEGIN
    DECLARE @WideOpenCount INT = 0;
    DECLARE @AzureServicesAllowed INT = 0;
    DECLARE @RuleCount INT = 0;

    -- Check for "Allow all Azure services" rule (usually 0.0.0.0 to 0.0.0.0 in some views or specific IDs)
    -- In Azure SQL, the 'Allow Azure services' toggle is often represented by a rule with 0.0.0.0 / 0.0.0.0
    SELECT @AzureServicesAllowed = COUNT(*) 
    FROM sys.firewall_rules 
    WHERE start_ip_address = '0.0.0.0' AND end_ip_address = '0.0.0.0';

    -- Check for wide open ranges
    SELECT @WideOpenCount = COUNT(*) 
    FROM sys.firewall_rules 
    WHERE (start_ip_address = '0.0.0.0' AND end_ip_address = '255.255.255.255');

    SELECT @RuleCount = COUNT(*) FROM sys.firewall_rules;

    IF @WideOpenCount > 0
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Public network access is wide open (0.0.0.0 - 255.255.255.255)';
    END
    ELSE IF @AzureServicesAllowed > 0
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Public network access restricted, but "Allow Azure services" is enabled';
    END
    ELSE IF @RuleCount = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = 'No public firewall rules configured; public access likely disabled';
    END
    ELSE
    BEGIN
        SET @Score = 3;
        SET @Finding = 'Public network access is restricted to specific IP ranges. Total rules: ' + CAST(@RuleCount AS NVARCHAR(10));
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;