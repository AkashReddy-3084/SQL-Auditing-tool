DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @AzureADCount INT = 0;
DECLARE @SQLCount INT = 0;
DECLARE @AuthMode INT = NULL;
DECLARE @IsSqlAuthEnabled BIT = NULL;

-- Count active Azure AD (External) logins
SELECT @AzureADCount = COUNT(*) FROM sys.server_principals WHERE type_desc = 'EXTERNAL_LOGIN' AND is_disabled = 0;

-- Count active SQL authentication logins
SELECT @SQLCount = COUNT(*) FROM sys.server_principals WHERE type_desc = 'SQL_LOGIN' AND is_disabled = 0;

-- Check SQL Server authentication mode (On-prem / MI)
IF EXISTS (SELECT 1 FROM sys.configurations WHERE name = 'SQL Server authentication mode')
BEGIN
    SELECT @AuthMode = value_in_use FROM sys.configurations WHERE name = 'SQL Server authentication mode';
END

-- Check SQL auth enabled flag (Azure SQL DB)
IF EXISTS (SELECT 1 FROM sys.sql_server_properties)
BEGIN
    SELECT @IsSqlAuthEnabled = is_sql_auth_enabled FROM sys.sql_server_properties;
END

-- Determine score based on direct configuration or principal ratio
-- Score 3: SQL auth disabled at server level (Windows Auth only mode = 1, or Azure SQL flag = 0)
IF @AuthMode = 1 OR @IsSqlAuthEnabled = 0
BEGIN
    SET @Score = 3;
END
ELSE IF @AzureADCount > @SQLCount
BEGIN
    SET @Score = 2;
END
ELSE IF @AzureADCount > 0
BEGIN
    SET @Score = 1;
END
ELSE
BEGIN
    SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;