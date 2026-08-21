-- Checklist: No shared/generic accounts for administrative or application access
-- Scope: SERVER
-- Scoring: 3=No shared/generic accounts found; 2=Shared/generic accounts found but none have administrative privileges; 1=One shared/generic account has administrative privileges; 0=Two or more shared/generic accounts have administrative privileges.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @GenericLogins TABLE (
    LoginName NVARCHAR(256),
    IsAdmin BIT
);

INSERT INTO @GenericLogins (LoginName, IsAdmin)
SELECT
    sp.name,
    CASE WHEN EXISTS (
        SELECT 1 FROM sys.server_role_members srm
        JOIN sys.server_principals srp ON srm.role_principal_id = srp.principal_id
        WHERE srm.member_principal_id = sp.principal_id
          AND srp.name IN ('sysadmin', 'securityadmin', 'serveradmin', 'setupadmin', 'processadmin', 'diskadmin', 'dbcreator', 'bulkadmin')
    ) THEN 1 ELSE 0 END
FROM sys.server_principals sp
WHERE sp.type IN ('S', 'U', 'G')
  AND sp.name NOT LIKE 'NT %'
  AND sp.name NOT LIKE 'BUILTIN\%'
  AND sp.name NOT LIKE '%\%'
  AND sp.name NOT LIKE '##%'
  AND sp.name NOT IN ('dbo', 'guest', 'public', 'INFORMATION_SCHEMA', 'sys', 'NT AUTHORITY\SYSTEM', 'NT AUTHORITY\NETWORK SERVICE', 'NT AUTHORITY\LOCAL SERVICE')
  AND (
      LOWER(sp.name) LIKE '%admin%' OR LOWER(sp.name) LIKE '%app%' OR LOWER(sp.name) LIKE '%service%' OR LOWER(sp.name) LIKE '%shared%' OR LOWER(sp.name) LIKE '%generic%' OR LOWER(sp.name) LIKE '%test%' OR LOWER(sp.name) LIKE '%dev%' OR LOWER(sp.name) LIKE '%prod%' OR LOWER(sp.name) LIKE '%etl%' OR LOWER(sp.name) LIKE '%report%' OR LOWER(sp.name) LIKE '%backup%' OR LOWER(sp.name) LIKE '%monitor%' OR LOWER(sp.name) LIKE '%temp%' OR LOWER(sp.name) LIKE '%user%' OR LOWER(sp.name) LIKE '%account%' OR LOWER(sp.name) LIKE '%login%' OR LOWER(sp.name) LIKE '%password%' OR LOWER(sp.name) LIKE '%default%' OR LOWER(sp.name) LIKE '%root%' OR LOWER(sp.name) LIKE '%administrator%' OR LOWER(sp.name) LIKE '%svc%' OR LOWER(sp.name) LIKE '%helpdesk%' OR LOWER(sp.name) LIKE '%support%' OR LOWER(sp.name) LIKE '%informati%' OR LOWER(sp.name) LIKE '%sysadmin%'
  );

DECLARE @TotalGeneric INT = (SELECT COUNT(*) FROM @GenericLogins);
DECLARE @AdminGeneric INT = (SELECT COUNT(*) FROM @GenericLogins WHERE IsAdmin = 1);

SET @Score = CASE
    WHEN @TotalGeneric = 0 THEN 3
    WHEN @AdminGeneric = 0 THEN 2
    WHEN @AdminGeneric = 1 THEN 1
    ELSE 0
END;

SET @Finding = CASE
    WHEN @TotalGeneric = 0 THEN 'No shared/generic accounts found.'
    WHEN @AdminGeneric = 0 THEN 'Shared/generic accounts found but none have administrative privileges: ' + ISNULL((SELECT STRING_AGG(LoginName, ', ') FROM @GenericLogins), 'None')
    ELSE 'Shared/generic accounts with administrative privileges found: ' + ISNULL((SELECT STRING_AGG(LoginName, ', ') FROM @GenericLogins WHERE IsAdmin = 1), 'None')
END;

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;