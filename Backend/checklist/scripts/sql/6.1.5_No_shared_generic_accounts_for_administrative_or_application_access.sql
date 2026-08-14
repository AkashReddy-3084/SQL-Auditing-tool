DECLARE @Score INT = 3;
DECLARE @Result NVARCHAR(10) = 'Pass';
DECLARE @GenericCount INT = 0;

-- Define generic/shared account patterns
DECLARE @Patterns TABLE (Pattern NVARCHAR(50));
INSERT INTO @Patterns VALUES ('sa'), ('admin'), ('administrator'), ('app'), ('application'), ('service'), ('svc'), ('shared'), ('generic'), ('test'), ('temp'), ('backup'), ('monitor'), ('dbadmin'), ('sysadmin');

-- Count distinct generic accounts that are enabled and have high privileges
SELECT @GenericCount = COUNT(DISTINCT sp.principal_id)
FROM sys.server_principals sp
INNER JOIN @Patterns p ON sp.name LIKE '%' + p.Pattern + '%'
WHERE sp.type IN ('S', 'U') -- SQL or Windows login
  AND sp.is_disabled = 0
  AND EXISTS (
      SELECT 1
      FROM sys.server_role_members srm
      INNER JOIN sys.server_principals srp ON srm.role_principal_id = srp.principal_id
      WHERE srm.member_principal_id = sp.principal_id
        AND srp.name IN ('sysadmin', 'securityadmin')
  );

-- Adjust score based on count
SET @Score = CASE 
    WHEN @GenericCount = 0 THEN 3
    WHEN @GenericCount = 1 THEN 2
    WHEN @GenericCount = 2 THEN 1
    ELSE 0
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;