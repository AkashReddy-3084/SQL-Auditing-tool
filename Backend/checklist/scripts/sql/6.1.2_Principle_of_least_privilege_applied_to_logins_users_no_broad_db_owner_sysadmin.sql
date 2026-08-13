-- Checklist: Principle of least privilege applied to logins/users (no broad db_owner/sysadmin)
-- Scope: SERVER
-- Scoring: 3 = 0 sysadmin/db_owner members (excluding sa/dbo), 2 = 1-3 members, 1 = 4-6 members, 0 = >6 members
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @TotalBroadPrivileges INT = 0;

-- Count sysadmin members (excluding sa) - only available on-prem / MI
IF OBJECT_ID('sys.server_role_members') IS NOT NULL
BEGIN
    SELECT @TotalBroadPrivileges = COUNT(*)
    FROM sys.server_role_members srm
    JOIN sys.server_principals sp ON srm.member_principal_id = sp.principal_id
    JOIN sys.server_principals srp ON srm.role_principal_id = srp.principal_id
    WHERE srp.name = 'sysadmin' AND sp.name <> 'sa';
END

-- Count db_owner members across all user databases
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DbCount INT = 0;

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        SELECT @DbCount = COUNT(*) FROM sys.database_role_members drm
        JOIN sys.database_principals dp ON drm.member_principal_id = dp.principal_id
        JOIN sys.database_principals drp ON drm.role_principal_id = drp.principal_id
        WHERE drp.name = ''db_owner'' AND dp.name NOT IN (''dbo'', ''guest'');';
        EXEC sp_executesql @Sql, N'@DbCount INT OUTPUT', @DbCount = @DbCount OUTPUT;
        SET @TotalBroadPrivileges = @TotalBroadPrivileges + @DbCount;
    END TRY
    BEGIN CATCH
        -- Skip inaccessible databases
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Assign score based on total count
SET @Score = CASE 
    WHEN @TotalBroadPrivileges = 0 THEN 3
    WHEN @TotalBroadPrivileges BETWEEN 1 AND 3 THEN 2
    WHEN @TotalBroadPrivileges BETWEEN 4 AND 6 THEN 1
    ELSE 0
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score;