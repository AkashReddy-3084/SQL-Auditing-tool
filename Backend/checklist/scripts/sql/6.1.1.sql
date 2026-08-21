-- Checklist: Microsoft Entra ID (Azure AD) authentication used where possible (over SQL auth)
-- Scope: SERVER
-- Scoring: 3 = Entra ID principals exist and outnumber SQL logins; 2 = Entra ID principals exist; 1 = Only SQL logins exist; 0 = No principals found or error.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Could not determine authentication types';

DECLARE @EntraCount INT = 0;
DECLARE @SqlCount INT = 0;

-- Azure SQL Database (EngineEdition 5) handles server-level principals differently; 
-- we check the connected database's principals.
IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @DatabaseQueried = DB_NAME();
    
    SELECT @EntraCount = COUNT(*) 
    FROM sys.database_principals 
    WHERE type IN ('ExternalUser', 'ExternalGroup');

    SELECT @SqlCount = COUNT(*) 
    FROM sys.database_principals 
    WHERE type IN ('SQL_USER');
END
ELSE
BEGIN
    -- SQL Server / Managed Instance: Check server-level logins
    SELECT @EntraCount = COUNT(*) 
    FROM sys.server_principals 
    WHERE type IN ('ExternalLogin');

    SELECT @SqlCount = COUNT(*) 
    FROM sys.server_principals 
    WHERE type = 'SQL_LOGIN' AND name NOT LIKE '##%';
END

IF @EntraCount > 0 AND @SqlCount = 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'Only Entra ID authentication used. Entra Count: ' + CAST(@EntraCount AS NVARCHAR(10)) + ', SQL Count: 0';
END
ELSE IF @EntraCount > 0 AND @EntraCount >= @SqlCount
BEGIN
    SET @Score = 3;
    SET @Finding = 'Entra ID preferred. Entra Count: ' + CAST(@EntraCount AS NVARCHAR(10)) + ', SQL Count: ' + CAST(@SqlCount AS NVARCHAR(10));
END
ELSE IF @EntraCount > 0
BEGIN
    SET @Score = 2;
    SET @Finding = 'Entra ID used, but SQL logins predominate. Entra Count: ' + CAST(@EntraCount AS NVARCHAR(10)) + ', SQL Count: ' + CAST(@SqlCount AS NVARCHAR(10));
END
ELSE IF @SqlCount > 0
BEGIN
    SET @Score = 1;
    SET @Finding = 'Only SQL authentication found. SQL Count: ' + CAST(@SqlCount AS NVARCHAR(10));
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = 'No SQL or Entra ID principals identified';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;