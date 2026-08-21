-- Checklist: Microsoft Entra ID (Azure AD) authentication used where possible (over SQL auth)
-- Scope: SERVER
-- Scoring: 3: Zero SQL auth logins; 2: 1-2 SQL auth logins; 1: >2 SQL auth logins but Azure AD logins exist; 0: >2 SQL auth logins and no Azure AD logins.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @SqlLoginCount INT = 0;
DECLARE @AadLoginCount INT = 0;
DECLARE @SqlLoginNames NVARCHAR(MAX) = '';

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    SELECT @SqlLoginCount = COUNT(*) FROM sys.database_principals WHERE type_desc = 'SQL_USER';
    SELECT @AadLoginCount = COUNT(*) FROM sys.database_principals WHERE type_desc = 'EXTERNAL_USER';
    SELECT @SqlLoginNames = STRING_AGG(name, ', ') FROM sys.database_principals WHERE type_desc = 'SQL_USER';
END
ELSE -- SQL Server / Azure SQL MI
BEGIN
    SELECT @SqlLoginCount = COUNT(*) FROM sys.server_principals WHERE type_desc = 'SQL_LOGIN';
    SELECT @AadLoginCount = COUNT(*) FROM sys.server_principals WHERE type_desc = 'EXTERNAL_LOGIN';
    SELECT @SqlLoginNames = STRING_AGG(name, ', ') FROM sys.server_principals WHERE type_desc = 'SQL_LOGIN';
END

IF @SqlLoginCount = 0
    SET @Score = 3;
ELSE IF @SqlLoginCount <= 2
    SET @Score = 2;
ELSE IF @AadLoginCount > 0
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Finding = CASE 
    WHEN @SqlLoginCount = 0 THEN 'No SQL authentication logins found.'
    ELSE 'SQL authentication logins found: ' + @SqlLoginNames
END;

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;