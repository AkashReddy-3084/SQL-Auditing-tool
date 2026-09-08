DECLARE @Score int;
DECLARE @SysAdmins TABLE (
    name sysname,
    type_desc nvarchar(60)
);

INSERT INTO @SysAdmins (name, type_desc)
SELECT p.name, p.type_desc
FROM sys.server_role_members rm
JOIN sys.server_principals p ON rm.member_principal_id = p.principal_id
JOIN sys.server_principals r ON rm.role_principal_id = r.principal_id
WHERE r.name = 'sysadmin'
  AND p.name NOT LIKE 'NT SERVICE\%'
  AND p.name NOT LIKE 'NT AUTHORITY\%'
  AND p.name != 'sa';

DECLARE @Count int = (SELECT COUNT(*) FROM @SysAdmins);
DECLARE @DatabaseQueried nvarchar(128) = DB_NAME();
DECLARE @Finding nvarchar(max);
DECLARE @Result nvarchar(50);

IF @Count > 0
BEGIN
    DECLARE @Names nvarchar(max);
    SELECT @Names = STRING_AGG(name, ', ') FROM @SysAdmins;
    SET @Finding = 'Found ' + CAST(@Count AS varchar(10)) + ' non-default principals in sysadmin role: ' + @Names;
    SET @Score = 3;
END
ELSE
BEGIN
    SET @Finding = 'No non-default principals found in sysadmin role.';
    SET @Score = 0;
END

SET @Result = CASE WHEN @Score = 0 THEN 'Pass' WHEN @Score = 3 THEN 'Review' ELSE 'Fail' END;

SELECT 
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;