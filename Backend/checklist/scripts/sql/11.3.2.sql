-- Checklist: Production access restricted (no developer write/deploy)
-- Scope: DATABASE
-- Scoring: 3 = no sysadmin members, database writers, or broad DDL grants; 2 = one category has evidence; 1 = two categories have evidence; 0 = all three categories have evidence or a source is unavailable
-- NOTE: Automated evidence only; account ownership and deployment responsibility require human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Production access evidence unavailable';
DECLARE @SysadminCount INT = 0;
DECLARE @DatabaseWriterCount INT = 0;
DECLARE @DdlGrantCount INT = 0;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT @SysadminCount = COUNT(*)
    FROM sys.server_role_members AS rm
    INNER JOIN sys.server_principals AS r ON r.principal_id = rm.role_principal_id
    INNER JOIN sys.server_principals AS m ON m.principal_id = rm.member_principal_id
    WHERE r.name = N'sysadmin'
      AND m.name NOT LIKE N'NT SERVICE%'
      AND m.name NOT LIKE N'##%';

    SELECT @DatabaseWriterCount = COUNT(*)
    FROM sys.database_role_members AS rm
    INNER JOIN sys.database_principals AS r ON r.principal_id = rm.role_principal_id
    INNER JOIN sys.database_principals AS m ON m.principal_id = rm.member_principal_id
    WHERE r.name IN (N'db_owner', N'db_ddladmin')
      AND m.principal_id > 4;

    SELECT @DdlGrantCount = COUNT(*)
    FROM sys.database_permissions
    WHERE permission_name IN (N'ALTER', N'CONTROL', N'ALTER ANY SCHEMA')
      AND state_desc = N'GRANT';
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

SET @Score = CASE
    WHEN @ReadError = 1 THEN 0
    WHEN @SysadminCount = 0 AND @DatabaseWriterCount = 0 AND @DdlGrantCount = 0 THEN 3
    WHEN (@SysadminCount > 0 AND @DatabaseWriterCount = 0 AND @DdlGrantCount = 0)
      OR (@SysadminCount = 0 AND @DatabaseWriterCount > 0 AND @DdlGrantCount = 0)
      OR (@SysadminCount = 0 AND @DatabaseWriterCount = 0 AND @DdlGrantCount > 0) THEN 2
    WHEN (@SysadminCount > 0 AND @DatabaseWriterCount > 0 AND @DdlGrantCount = 0)
      OR (@SysadminCount > 0 AND @DatabaseWriterCount = 0 AND @DdlGrantCount > 0)
      OR (@SysadminCount = 0 AND @DatabaseWriterCount > 0 AND @DdlGrantCount > 0) THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'excluded sysadmin members = ', @SysadminCount,
    N'; database members in db_owner/db_ddladmin = ', @DatabaseWriterCount,
    N'; granted ALTER/CONTROL/ALTER ANY SCHEMA permissions = ', @DdlGrantCount,
    CASE WHEN @ReadError = 1 THEN N'; one or more security sources could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;