-- Checklist: Public network access disabled or tightly restricted (Azure SQL)
-- Scope: SERVER
-- Scoring: 0=Unrestricted public access (0.0.0.0-255.255.255.255); 1=Multiple public IP rules/broad subnets; 2=Restricted to specific IPs or Azure services; 3=No public IP rules (private endpoints only) or firewall disabled
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

IF OBJECT_ID('sys.firewall_rules') IS NOT NULL
BEGIN
    DECLARE @BroadPublic INT = 0;
    DECLARE @AzureServices INT = 0;
    DECLARE @PublicRules INT = 0;

    SELECT 
        @BroadPublic = COUNT(CASE WHEN start_ip_address = '0.0.0.0' AND end_ip_address = '255.255.255.255' THEN 1 END),
        @AzureServices = COUNT(CASE WHEN name = 'AllowAzureServices' THEN 1 END),
        @PublicRules = COUNT(*)
    FROM sys.firewall_rules;

    IF @BroadPublic > 0 SET @Score = 0;
    ELSE IF @PublicRules > 5 SET @Score = 1;
    ELSE IF @AzureServices > 0 OR @PublicRules BETWEEN 1 AND 5 SET @Score = 2;
    ELSE SET @Score = 3;
END
ELSE
BEGIN
    -- Non-Azure SQL environment; cannot verify Azure-specific public access setting
    SET @Score = 1;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;