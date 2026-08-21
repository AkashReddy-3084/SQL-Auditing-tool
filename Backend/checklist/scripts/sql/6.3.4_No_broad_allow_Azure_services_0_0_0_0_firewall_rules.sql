-- Checklist: No broad "allow Azure services" / 0.0.0.0 firewall rules
-- Scope: SERVER
-- Scoring: 3=No broad rules found; 2=One broad rule found or on-prem SQL Server (OS firewall not queryable); 1=Two broad rules found; 0=Three or more broad rules found.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @RuleCount INT = 0;
DECLARE @RuleNames NVARCHAR(MAX) = '';

IF @EngineEdition IN (5, 8) OR OBJECT_ID('sys.firewall_rules') IS NOT NULL
BEGIN
    SELECT @RuleCount = COUNT(*),
           @RuleNames = STRING_AGG(name, ', ')
    FROM sys.firewall_rules
    WHERE start_ip_address = '0.0.0.0'
      AND end_ip_address = '255.255.255.255';

    IF @RuleCount = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = 'No broad firewall rules (0.0.0.0/0 or AllowAzureServices) detected.';
    END
    ELSE
    BEGIN
        SET @Score = CASE
            WHEN @RuleCount = 1 THEN 2
            WHEN @RuleCount = 2 THEN 1
            ELSE 0
        END;
        SET @Finding = CAST(@RuleCount AS NVARCHAR(10)) + ' broad firewall rule(s) found: ' + @RuleNames + ' (0.0.0.0 - 255.255.255.255)';
    END
END
ELSE
BEGIN
    SET @Score = 2;
    SET @Finding = 'On-prem SQL Server: OS-level firewall rules are not queryable via T-SQL. Manual verification required.';
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;