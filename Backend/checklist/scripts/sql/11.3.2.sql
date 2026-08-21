/*
    Checklist Item : 11.3.2 - Production access restricted (no developer write/deploy)
    Scope          : SERVER
    Script Type    : T-SQL (read-only)

    Enumerates every principal that holds write (INSERT/UPDATE/DELETE) or deploy
    (DDL / ALTER / CONTROL / privileged role) capability at server level or in any
    accessible user database, excluding platform built-ins and service accounts.
    No data or configuration is modified; only temp tables are populated.
*/

SET NOCOUNT ON;

DECLARE @IsAzureSqlDb    bit,
        @Score           int,
        @Result          nvarchar(20),
        @Finding         nvarchar(max),
        @DatabaseQueried nvarchar(256),
        @Principals      int,
        @GrantCount      int,
        @DbScanned       int = 0,
        @DbSkipped       int = 0,
        @TopList         nvarchar(max),
        @ServerName      nvarchar(128);

SET @ServerName = CONVERT(nvarchar(128), SERVERPROPERTY('ServerName'));
SET @IsAzureSqlDb = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#Elevated') IS NOT NULL DROP TABLE #Elevated;
CREATE TABLE #Elevated
(
    PrincipalName sysname        NOT NULL,
    PrincipalType nvarchar(60)   NOT NULL,
    ScopeName     nvarchar(258)  NOT NULL,
    GrantDetail   nvarchar(256)  NOT NULL,
    RightKind     nvarchar(10)   NOT NULL
);

/* ---------- Server-level privileges (not applicable to Azure SQL Database) ---------- */
IF @IsAzureSqlDb = 0
BEGIN
    BEGIN TRY
        INSERT INTO #Elevated (PrincipalName, PrincipalType, ScopeName, GrantDetail, RightKind)
        SELECT  mp.name,
                mp.type_desc,
                N'SERVER',
                N'Server role membership: ' + rp.name,
                N'DEPLOY'
        FROM sys.server_role_members AS srm
        INNER JOIN sys.server_principals AS rp ON rp.principal_id = srm.role_principal_id
        INNER JOIN sys.server_principals AS mp ON mp.principal_id = srm.member_principal_id
        WHERE rp.name IN (N'sysadmin', N'serveradmin', N'setupadmin', N'securityadmin', N'dbcreator')
          AND mp.name <> N'sa'
          AND mp.name NOT LIKE N'##%'
          AND mp.name NOT LIKE N'NT SERVICE\%'
          AND mp.name NOT LIKE N'NT AUTHORITY\%'
          AND mp.is_disabled = 0;

        INSERT INTO #Elevated (PrincipalName, PrincipalType, ScopeName, GrantDetail, RightKind)
        SELECT  sp.name,
                sp.type_desc,
                N'SERVER',
                N'Server permission: ' + perm.permission_name + N' (' + perm.state_desc + N')',
                N'DEPLOY'
        FROM sys.server_permissions AS perm
        INNER JOIN sys.server_principals AS sp ON sp.principal_id = perm.grantee_principal_id
        WHERE perm.state IN ('G', 'W')
          AND perm.permission_name IN (N'CONTROL SERVER', N'ALTER ANY DATABASE', N'CREATE ANY DATABASE',
                                       N'ALTER ANY LOGIN', N'ALTER ANY SERVER ROLE')
          AND sp.name <> N'sa'
          AND sp.name NOT LIKE N'##%'
          AND sp.name NOT LIKE N'NT SERVICE\%'
          AND sp.name NOT LIKE N'NT AUTHORITY\%'
          AND sp.is_disabled = 0;
    END TRY
    BEGIN CATCH
        SET @DbSkipped = @DbSkipped + 1;
    END CATCH
END

/* ---------- Database-level privileges ---------- */
IF @IsAzureSqlDb = 1
BEGIN
    /* Azure SQL Database: only the connected database is reachable. */
    BEGIN TRY
        INSERT INTO #Elevated (PrincipalName, PrincipalType, ScopeName, GrantDetail, RightKind)
        SELECT  mp.name,
                mp.type_desc,
                DB_NAME(),
                N'Database role membership: ' + rp.name,
                CASE WHEN rp.name = N'db_datawriter' THEN N'WRITE' ELSE N'DEPLOY' END
        FROM sys.database_role_members AS drm
        INNER JOIN sys.database_principals AS rp ON rp.principal_id = drm.role_principal_id
        INNER JOIN sys.database_principals AS mp ON mp.principal_id = drm.member_principal_id
        WHERE rp.name IN (N'db_owner', N'db_ddladmin', N'db_datawriter', N'db_accessadmin', N'db_securityadmin')
          AND mp.name NOT IN (N'dbo', N'guest', N'public', N'sys', N'INFORMATION_SCHEMA')
          AND mp.name NOT LIKE N'##%'
          AND mp.name NOT LIKE N'NT SERVICE\%'
          AND mp.name NOT LIKE N'NT AUTHORITY\%';

        INSERT INTO #Elevated (PrincipalName, PrincipalType, ScopeName, GrantDetail, RightKind)
        SELECT  dp.name,
                dp.type_desc,
                DB_NAME(),
                N'Database permission: ' + perm.permission_name + N' on ' + perm.class_desc + N' (' + perm.state_desc + N')',
                CASE WHEN perm.permission_name IN (N'INSERT', N'UPDATE', N'DELETE') THEN N'WRITE' ELSE N'DEPLOY' END
        FROM sys.database_permissions AS perm
        INNER JOIN sys.database_principals AS dp ON dp.principal_id = perm.grantee_principal_id
        WHERE perm.state IN ('G', 'W')
          AND perm.permission_name IN (N'INSERT', N'UPDATE', N'DELETE', N'ALTER', N'CONTROL',
                                       N'TAKE OWNERSHIP', N'ALTER ANY SCHEMA', N'CREATE TABLE',
                                       N'CREATE PROCEDURE', N'CREATE VIEW', N'CREATE FUNCTION')
          AND dp.name NOT IN (N'dbo', N'guest', N'public', N'sys', N'INFORMATION_SCHEMA')
          AND dp.name NOT LIKE N'##%'
          AND dp.name NOT LIKE N'NT SERVICE\%'
          AND dp.name NOT LIKE N'NT AUTHORITY\%';

        SET @DbScanned = 1;
    END TRY
    BEGIN CATCH
        SET @DbSkipped = 1;
    END CATCH
END
ELSE
BEGIN
    DECLARE @db  sysname,
            @sql nvarchar(max);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.is_in_standby = 0
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @sql = N'
            INSERT INTO #Elevated (PrincipalName, PrincipalType, ScopeName, GrantDetail, RightKind)
            SELECT  mp.name,
                    mp.type_desc,
                    @dbname,
                    N''Database role membership: '' + rp.name,
                    CASE WHEN rp.name = N''db_datawriter'' THEN N''WRITE'' ELSE N''DEPLOY'' END
            FROM ' + QUOTENAME(@db) + N'.sys.database_role_members AS drm
            INNER JOIN ' + QUOTENAME(@db) + N'.sys.database_principals AS rp ON rp.principal_id = drm.role_principal_id
            INNER JOIN ' + QUOTENAME(@db) + N'.sys.database_principals AS mp ON mp.principal_id = drm.member_principal_id
            WHERE rp.name IN (N''db_owner'', N''db_ddladmin'', N''db_datawriter'', N''db_accessadmin'', N''db_securityadmin'')
              AND mp.name NOT IN (N''dbo'', N''guest'', N''public'', N''sys'', N''INFORMATION_SCHEMA'')
              AND mp.name NOT LIKE N''##%''
              AND mp.name NOT LIKE N''NT SERVICE\%''
              AND mp.name NOT LIKE N''NT AUTHORITY\%'';

            INSERT INTO #Elevated (PrincipalName, PrincipalType, ScopeName, GrantDetail, RightKind)
            SELECT  dp.name,
                    dp.type_desc,
                    @dbname,
                    N''Database permission: '' + perm.permission_name + N'' on '' + perm.class_desc + N'' ('' + perm.state_desc + N'')'',
                    CASE WHEN perm.permission_name IN (N''INSERT'', N''UPDATE'', N''DELETE'') THEN N''WRITE'' ELSE N''DEPLOY'' END
            FROM ' + QUOTENAME(@db) + N'.sys.database_permissions AS perm
            INNER JOIN ' + QUOTENAME(@db) + N'.sys.database_principals AS dp ON dp.principal_id = perm.grantee_principal_id
            WHERE perm.state IN (''G'', ''W'')
              AND perm.permission_name IN (N''INSERT'', N''UPDATE'', N''DELETE'', N''ALTER'', N''CONTROL'',
                                           N''TAKE OWNERSHIP'', N''ALTER ANY SCHEMA'', N''CREATE TABLE'',
                                           N''CREATE PROCEDURE'', N''CREATE VIEW'', N''CREATE FUNCTION'')
              AND dp.name NOT IN (N''dbo'', N''guest'', N''public'', N''sys'', N''INFORMATION_SCHEMA'')
              AND dp.name NOT LIKE N''##%''
              AND dp.name NOT LIKE N''NT SERVICE\%''
              AND dp.name NOT LIKE N''NT AUTHORITY\%'';';

            EXEC sys.sp_executesql @sql, N'@dbname sysname', @dbname = @db;

            SET @DbScanned = @DbScanned + 1;
        END TRY
        BEGIN CATCH
            SET @DbSkipped = @DbSkipped + 1;
        END CATCH

        FETCH NEXT FROM db_cursor INTO @db;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

/* ---------- Evaluate ---------- */
SELECT @Principals = COUNT(DISTINCT PrincipalName),
       @GrantCount = COUNT(*)
FROM #Elevated;

SET @Principals = ISNULL(@Principals, 0);
SET @GrantCount = ISNULL(@GrantCount, 0);

SET @TopList = STUFF((
        SELECT TOP (10) N', ' + x.PrincipalName
        FROM (SELECT DISTINCT PrincipalName FROM #Elevated) AS x
        ORDER BY x.PrincipalName
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
SET @TopList = ISNULL(@TopList, N'(none)');

SET @Score = CASE
                WHEN @Principals <= 3  THEN 3
                WHEN @Principals <= 8  THEN 2
                WHEN @Principals <= 15 THEN 1
                ELSE 0
             END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @DatabaseQueried = CASE
                          WHEN @IsAzureSqlDb = 1 THEN DB_NAME()
                          ELSE ISNULL(@ServerName, N'SERVER') + N' (all accessible user databases)'
                       END;

SET @Finding = N'Found ' + CAST(@Principals AS nvarchar(20))
             + N' distinct non-service principal(s) holding write or deploy privileges across '
             + CAST(@DbScanned AS nvarchar(20)) + N' scanned database(s) ('
             + CAST(@GrantCount AS nvarchar(20)) + N' total grant/role entries; '
             + CAST(@DbSkipped AS nvarchar(20)) + N' scope(s) skipped as inaccessible). '
             + N'Deploy-capable entries: '
             + CAST((SELECT COUNT(*) FROM #Elevated WHERE RightKind = N'DEPLOY') AS nvarchar(20))
             + N'; write-capable entries: '
             + CAST((SELECT COUNT(*) FROM #Elevated WHERE RightKind = N'WRITE') AS nvarchar(20))
             + N'. Principals (first 10): ' + @TopList
             + N'. Reconcile this list against the approved DBA/service-account roster: any developer identity present indicates production write/deploy access is not restricted.';

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;

IF OBJECT_ID('tempdb..#Elevated') IS NOT NULL DROP TABLE #Elevated;