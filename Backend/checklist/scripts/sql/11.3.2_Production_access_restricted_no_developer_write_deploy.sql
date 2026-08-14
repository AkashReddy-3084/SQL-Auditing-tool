DECLARE @Score INT = 3;
DECLARE @Result NVARCHAR(10) = 'Pass';
DECLARE @DevLoginCount INT = 0;
DECLARE @DisabledDevCount INT = 0;
DECLARE @WriteDevCount INT = 0;

-- Check for enabled developer/test/qa logins
SELECT @DevLoginCount = COUNT(*)
FROM sys.server_principals
WHERE type IN ('S', 'U')
  AND is_disabled = 0
  AND (name LIKE '%dev%' OR name LIKE '%developer%' OR name LIKE '%test%' OR name LIKE '%qa%' OR name LIKE '%staging%')
  AND name NOT LIKE '##%';

-- Check if any enabled developer logins have write/deploy permissions (sysadmin, dbcreator)
SELECT @WriteDevCount = COUNT(*)
FROM sys.server_principals sp
JOIN sys.server_role_members srm ON sp.principal_id = srm.member_principal_id
JOIN sys.server_principals sr ON srm.role_principal_id = sr.principal_id
WHERE sp.type IN ('S', 'U')
  AND sp.is_disabled = 0
  AND (sp.name LIKE '%dev%' OR sp.name LIKE '%developer%' OR sp.name LIKE '%test%' OR sp.name LIKE '%qa%' OR sp.name LIKE '%staging%')
  AND sr.name IN ('sysadmin', 'dbcreator')
  AND sp.name NOT LIKE '##%';

-- Check for CONTROL SERVER permission (direct query, no OBJECT_ID wrapper)
DECLARE @ControlServerCount INT = 0;
SELECT @ControlServerCount = COUNT(*)
FROM sys.server_permissions sp
JOIN sys.server_principals s ON sp.grantee_principal_id = s.principal_id
WHERE s.type IN ('S', 'U')
  AND s.is_disabled = 0
  AND (s.name LIKE '%dev%' OR s.name LIKE '%developer%' OR s.name LIKE '%test%' OR s.name LIKE '%qa%' OR s.name LIKE '%staging%')
  AND sp.permission_name = 'CONTROL SERVER'
  AND s.name NOT LIKE '##%';

SET @WriteDevCount = @WriteDevCount + @ControlServerCount;

-- Check for disabled developer logins
SELECT @DisabledDevCount = COUNT(*)
FROM sys.server_principals
WHERE type IN ('S', 'U')
  AND is_disabled = 1
  AND (name LIKE '%dev%' OR name LIKE '%developer%' OR name LIKE '%test%' OR name LIKE '%qa%' OR name LIKE '%staging%')
  AND name NOT LIKE '##%';

-- Determine score based on findings
IF @WriteDevCount > 0
    SET @Score = 0;
ELSE IF @DisabledDevCount > 0
    SET @Score = 2;
ELSE IF @DevLoginCount > 0
    SET @Score = 1;
ELSE
    SET @Score = 3;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;