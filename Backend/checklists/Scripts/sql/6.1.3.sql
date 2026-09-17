SET NOCOUNT ON;

DECLARE @DirectUserGrantCount int = 0;
DECLARE @RoleGrantCount int = 0;
DECLARE @RoleMembershipCount int = 0;
DECLARE @DirectGrantExamples nvarchar(2000) = N'';
DECLARE @Result varchar(20) = 'Fail';
DECLARE @Score int = 0;
DECLARE @DatabaseQueried nvarchar(128) = N'None';
DECLARE @Finding nvarchar(4000) = N'No database found to be queried';

IF DB_NAME() NOT IN (N'master', N'model', N'msdb', N'tempdb')
BEGIN
    SET @DatabaseQueried = ISNULL(DB_NAME(), N'None');

    SELECT @DirectUserGrantCount = COUNT(*)
    FROM sys.database_permissions AS permission_entry
    INNER JOIN sys.database_principals AS grantee
        ON grantee.principal_id = permission_entry.grantee_principal_id
    WHERE grantee.type IN ('S', 'U', 'E', 'X')
      AND grantee.name NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys')
      AND permission_entry.state IN ('G', 'W', 'D', 'R');

    SELECT @RoleGrantCount = COUNT(*)
    FROM sys.database_permissions AS permission_entry
    INNER JOIN sys.database_principals AS grantee
        ON grantee.principal_id = permission_entry.grantee_principal_id
    WHERE grantee.type = 'R'
      AND permission_entry.state IN ('G', 'W', 'D', 'R');

    SELECT @RoleMembershipCount = COUNT(*)
    FROM sys.database_role_members;

    SELECT @DirectGrantExamples = ISNULL(STUFF((
        SELECT TOP (10)
            N'; ' + QUOTENAME(grantee.name) + N' ' + permission_entry.state_desc
            + N' ' + permission_entry.permission_name
            + CASE permission_entry.class
                WHEN 0 THEN N' ON DATABASE'
                WHEN 1 THEN N' ON ' + ISNULL(QUOTENAME(OBJECT_SCHEMA_NAME(permission_entry.major_id)), N'[unknown]')
                    + N'.' + ISNULL(QUOTENAME(OBJECT_NAME(permission_entry.major_id)), N'[unknown]')
                WHEN 3 THEN N' ON SCHEMA::' + ISNULL(QUOTENAME(SCHEMA_NAME(permission_entry.major_id)), N'[unknown]')
                ELSE N' (class ' + CONVERT(nvarchar(10), permission_entry.class) + N')'
              END
        FROM sys.database_permissions AS permission_entry
        INNER JOIN sys.database_principals AS grantee
            ON grantee.principal_id = permission_entry.grantee_principal_id
        WHERE grantee.type IN ('S', 'U', 'E', 'X')
          AND grantee.name NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys')
          AND permission_entry.state IN ('G', 'W', 'D', 'R')
        ORDER BY grantee.name, permission_entry.permission_name
        FOR XML PATH(''), TYPE
    ).value('.', 'nvarchar(max)'), 1, 2, N''), N'none available');

    IF @DirectUserGrantCount = 0
        SET @Score = 3;
    ELSE IF @RoleGrantCount > 0 OR @RoleMembershipCount > 0
        SET @Score = 2;
    ELSE
        SET @Score = 1;

    SET @Finding =
        N'Direct permissions assigned to individual users: ' + CONVERT(nvarchar(20), @DirectUserGrantCount)
        + N'; permissions assigned to database roles: ' + CONVERT(nvarchar(20), @RoleGrantCount)
        + N'; database role memberships: ' + CONVERT(nvarchar(20), @RoleMembershipCount)
        + CASE
            WHEN @DirectUserGrantCount = 0 THEN N'. No direct per-user permissions were found.'
            ELSE N'. Direct permission examples: ' + @DirectGrantExamples + N'.'
          END;
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;