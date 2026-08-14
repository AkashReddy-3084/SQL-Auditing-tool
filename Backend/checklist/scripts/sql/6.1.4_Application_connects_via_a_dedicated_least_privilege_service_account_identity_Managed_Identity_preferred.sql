SET NOCOUNT ON;
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

CREATE TABLE #SvcAccounts (
    PrincipalName NVARCHAR(256),
    IsManagedIdentity BIT,
    HasHighPriv BIT,
    HighPrivCount INT
);

-- Server-level evaluation using master database context
INSERT INTO #SvcAccounts (PrincipalName, IsManagedIdentity, HasHighPriv, HighPrivCount)
SELECT 
    sp.name,
    CASE WHEN sp.type = 'E' OR sp.name LIKE '%AzureAD%' OR sp.name LIKE '%managed%' THEN 1 ELSE 0 END,
    CASE WHEN EXISTS (
        SELECT 1 FROM master.sys.server_role_members srm
        JOIN master.sys.server_principals srp ON srm.role_principal_id = srp.principal_id
        WHERE srm.member_principal_id = sp.principal_id AND srp.name = 'sysadmin'
    ) THEN 1 ELSE 0 END,
    (SELECT COUNT(*) FROM master.sys.server_permissions spm 
     WHERE spm.grantee_principal_id = sp.principal_id 
     AND spm.permission_name IN ('CONTROL SERVER', 'ALTER ANY LOGIN', 'ALTER ANY LINKED SERVER', 'ALTER TRACE', 'SHUTDOWN'))
FROM master.sys.server_principals sp
WHERE sp.type IN ('S', 'U', 'E', 'G')
  AND sp.name NOT LIKE '##%'
  AND (sp.name LIKE '%svc%' OR sp.name LIKE '%app%' OR sp.name LIKE '%service%' OR sp.name LIKE '%identity%' OR sp.type = 'E');

-- Calculate score per checklist definition
DECLARE @TotalSvc INT = (SELECT COUNT(*) FROM #SvcAccounts);
DECLARE @RestrictedSvc INT = (SELECT COUNT(*) FROM #SvcAccounts WHERE HasHighPriv = 0 AND HighPrivCount = 0);

IF @TotalSvc = 0 
    SET @Score = 0; -- No service accounts found
ELSE IF @RestrictedSvc = 0 
    SET @Score = 0; -- All found accounts have sysadmin/db_owner or excessive privileges
ELSE IF @RestrictedSvc < @TotalSvc 
    SET @Score = 1; -- Service accounts exist but some have excessive privileges
ELSE 
    SET @Score = 2; -- Dedicated service accounts with restricted permissions (Managed Identity preferred)

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #SvcAccounts;
SELECT @Result AS Result, @Score AS Score;