DECLARE @Result NVARCHAR(10);
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, BroadRoleCount INT, Finding NVARCHAR(MAX));
CREATE TABLE #GlobalPrivs (PrincipalName NVARCHAR(MAX), RoleName NVARCHAR(100));

-- 1. Server Level: sysadmin check
INSERT INTO #GlobalPrivs (PrincipalName, RoleName)
SELECT p.name, 'sysadmin'
FROM sys.server_role_members rm
JOIN sys.server_principals p ON rm.member_principal_id = p.principal_id
JOIN sys.server_principals r ON rm.role_principal_id = r.principal_id
WHERE r.name = 'sysadmin' AND p.name NOT IN ('sa');

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    INSERT INTO #DbResults (DbName, BroadRoleCount, Finding)
    SELECT DB_NAME(),
           COUNT(*),
           CASE WHEN COUNT(*) = 0 THEN 'No db_owner found'
                ELSE 'db_owner: ' + STRING_AGG(p.name, ', ') END
    FROM sys.database_role_members rm
    JOIN sys.database_principals p ON rm.member_principal_id = p.principal_id
    JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
    WHERE r.name = 'db_owner' AND p.name NOT IN ('dbo');
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases
        WHERE database_id > 4 AND state = 0 AND HAS_DBACCESS(name) = 1;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'SELECT 
                COUNT(*),
                CASE WHEN COUNT(*) = 0 THEN ''No db_owner found''
                     ELSE ''db_owner: '' + STRING_AGG(p.name, '', '') END
                FROM ' + QUOTENAME(@DbName) + N'.sys.database_role_members rm
                JOIN ' + QUOTENAME(@DbName) + N'.sys.database_principals p ON rm.member_principal_id = p.principal_id
                JOIN ' + QUOTENAME(@DbName) + N'.sys.database_principals r ON rm.role_principal_id = r.principal_id
                WHERE r.name = ''db_owner'' AND p.name NOT IN (''dbo'');';

            DECLARE @DbCount INT, @DbFinding NVARCHAR(MAX);
            DECLARE @ParamDef NVARCHAR(MAX) = N'@DbCount INT OUTPUT, @DbFinding NVARCHAR(MAX) OUTPUT';
            
            EXEC sp_executesql @Sql, @ParamDef, @DbCount = @DbCount OUTPUT, @DbFinding = @DbFinding OUTPUT;
            
            INSERT INTO #DbResults (DbName, BroadRoleCount, Finding)
            VALUES (@DbName, ISNULL(@DbCount, 0), ISNULL(@DbFinding, 'No db_owner found'));
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, BroadRoleCount, Finding)
            VALUES (@DbName, 999, 'Evaluation failed: ' + ERROR_MESSAGE());
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

-- Calculate total broad roles across server and all databases
DECLARE @TotalBroadRoles INT = 0;
SELECT @TotalBroadRoles = @TotalBroadRoles + COUNT(*) FROM #GlobalPrivs;
SELECT @TotalBroadRoles = @TotalBroadRoles + ISNULL(SUM(BroadRoleCount), 0) FROM #DbResults;

-- Scoring Logic: 3 = no sysadmins (except sa) and no db_owners; 2 = 1-2 broad roles; 1 = 3-5 broad roles; 0 = >5 broad roles.
SET @Score = CASE 
    WHEN @TotalBroadRoles = 0 THEN 3 
    WHEN @TotalBroadRoles <= 2 THEN 2 
    WHEN @TotalBroadRoles <= 5 THEN 1 
    ELSE 0 
END;

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(DbName, ', ') FROM #DbResults), 'None');

-- Construct Finding
DECLARE @ServerFinding NVARCHAR(MAX) = '';
SELECT @ServerFinding = STRING_AGG(PrincipalName + ' (' + RoleName + ')', ', ') FROM #GlobalPrivs;

DECLARE @DbFindingAgg NVARCHAR(MAX) = '';
SELECT @DbFindingAgg = STRING_AGG(DbName + ': ' + Finding, '; ') FROM #DbResults;

SET @Finding = CASE 
    WHEN @TotalBroadRoles = 0 THEN 'No broad roles (sysadmin/db_owner) found.'
    ELSE 'Broad roles found: ' + 
         CASE WHEN @ServerFinding <> '' THEN @ServerFinding + ' ' ELSE '' END + 
         CASE WHEN @DbFindingAgg <> '' THEN '[' + @DbFindingAgg + ']' ELSE '' END
END;

IF @DatabaseQueried = 'None'
BEGIN
    SET @DatabaseQueried = 'None';
    SET @Finding = 'No database found to be queried';
    SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;