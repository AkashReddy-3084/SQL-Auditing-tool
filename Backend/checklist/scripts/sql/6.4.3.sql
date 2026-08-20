-- Checklist: Managed Identity used for service-to-service auth where supported
-- Scope: SERVER
-- Scoring: 3 = Only Azure AD/Managed Identity principals; 2 = Mixed mode with Managed Identities; 1 = Only SQL logins; 0 = No principals found

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No principals found';

DECLARE @SqlLoginCount INT = 0;
DECLARE @ManagedIdentityCount INT = 0;

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    -- Azure SQL DB: Scope is the current database
    SELECT @SqlLoginCount = COUNT(*) FROM sys.database_principals WHERE type = 'SQL_USER';
    SELECT @ManagedIdentityCount = COUNT(*) FROM sys.database_principals WHERE type IN ('EXTERNAL_USER', 'EXTERNAL_GROUP');
    SET @DatabaseQueried = DB_NAME();
END
ELSE
BEGIN
    -- SQL Server / MI: Scope is the server
    SELECT @SqlLoginCount = COUNT(*) FROM sys.server_principals WHERE type = 'SQL_LOGIN';
    SELECT @ManagedIdentityCount = COUNT(*) FROM sys.server_principals WHERE type IN ('EXTERNAL_LOGIN', 'EXTERNAL_GROUP');
    SET @DatabaseQueried = 'master';
END

IF @SqlLoginCount = 0 AND @ManagedIdentityCount > 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'Only Managed Identity/Azure AD principals found. SQL Logins: ' + CAST(@SqlLoginCount AS VARCHAR(10)) + ', Managed Identities: ' + CAST(@ManagedIdentityCount AS VARCHAR(10));
END
ELSE IF @SqlLoginCount > 0 AND @ManagedIdentityCount > 0
BEGIN
    SET @Score = 2;
    SET @Finding = 'Mixed mode authentication. SQL Logins: ' + CAST(@SqlLoginCount AS VARCHAR(10)) + ', Managed Identities: ' + CAST(@ManagedIdentityCount AS VARCHAR(10));
END
ELSE IF @SqlLoginCount > 0 AND @ManagedIdentityCount = 0
BEGIN
    SET @Score = 1;
    SET @Finding = 'Only SQL logins found. Managed Identities: 0';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = 'No identifiable principals found in the scope.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;