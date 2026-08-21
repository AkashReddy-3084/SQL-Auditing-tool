SET NOCOUNT ON;

/* 6.1.2 - Principle of least privilege applied to logins/users (no broad db_owner/sysadmin)
   Read-only: enumerates high-privilege role membership at server and database level. */

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @IsAzureSqlDb BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @DatabaseQueried NVARCHAR(256);
DECLARE @Result NVARCHAR(20);
DECLARE @Score INT;
DECLARE @Finding NVARCHAR(MAX);
DECLARE @Detail NVARCHAR(MAX);
DECLARE @ServerCount INT = 0;
DECLARE @DbCount INT = 0;
DECLARE @Total INT = 0;
DECLARE @DbScanned INT = 0;

IF OBJECT_ID('tempdb..#HighPriv') IS NOT NULL DROP TABLE #HighPriv;
CREATE TABLE #HighPriv
(
    ScopeLevel    NVARCHAR(20)  NOT NULL,
    DatabaseName  NVARCHAR(128) NOT NULL,
    PrincipalName NVARCHAR(256) NOT NULL,
    RoleName      NVARCHAR(128) NOT NULL
);

IF @IsAzureSqlDb = 1
BEGIN
    SET @DatabaseQueried = DB_NAME();
    SET @DbScanned = 1;

    BEGIN TRY
        INSERT INTO #HighPriv (ScopeLevel, DatabaseName, PrincipalName, RoleName)
        SELECT 'Database', DB_NAME(), dp.name, r.name
        FROM sys.database_role_members AS drm
        INNER JOIN sys.database_principals AS r ON r.principal_id = drm.role_principal_id
        INNER JOIN sys.database_principals AS dp ON dp.principal_id = drm.member_principal_id
        WHERE r.name IN (N'db_owner', N'db_securityadmin', N'db_accessadmin')
          AND dp.name NOT IN (N'dbo', N'guest')
          AND dp.name NOT LIKE N'##%'
          AND dp.type <> 'R';
    END TRY
    BEGIN CATCH
        /* insufficient permission to read database principals - leave set empty */
        SET @Detail = NULL;
    END CATCH
END
ELSE
BEGIN
    SET @DatabaseQueried = CONVERT(NVARCHAR(128), SERVERPROPERTY('ServerName'));

    BEGIN TRY
        INSERT INTO #HighPriv (ScopeLevel, DatabaseName, PrincipalName, RoleName)
        SELECT 'Server', N'(server)', sp.name, r.name
        FROM sys.server_role_members AS srm
        INNER JOIN sys.server_principals AS r ON r.principal_id = srm.role_principal_id
        INNER JOIN sys.server_principals AS sp ON sp.principal_id = srm.member_principal_id
        WHERE r.name IN (N'sysadmin', N'securityadmin', N'serveradmin')
          AND sp.name <> N'sa'
          AND sp.name NOT LIKE N'##%'
          AND sp.name NOT LIKE N'NT SERVICE\%'
          AND sp.name NOT LIKE N'NT AUTHORITY\%'
          AND sp.is_disabled = 0
          AND sp.type <> 'R';
    END TRY
    BEGIN CATCH
        /* insufficient permission to read server principals */
        SET @Detail = NULL;
    END CATCH

    DECLARE @db SYSNAME;
    DECLARE @sql NVARCHAR(MAX);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.is_read_only = 0
          AND DATABASEPROPERTYEX(d.name, 'Updateability') = 'READ_WRITE'
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @DbScanned = @DbScanned + 1;

        SET @sql = N'SELECT ''Database'', @dbname, dp.name, r.name
                     FROM ' + QUOTENAME(@db) + N'.sys.database_role_members AS drm
                     INNER JOIN ' + QUOTENAME(@db) + N'.sys.database_principals AS r
                         ON r.principal_id = drm.role_principal_id
                     INNER JOIN ' + QUOTENAME(@db) + N'.sys.database_principals AS dp
                         ON dp.principal_id = drm.member_principal_id
                     WHERE r.name IN (N''db_owner'', N''db_securityadmin'', N''db_accessadmin'')
                       AND dp.name NOT IN (N''dbo'', N''guest'')
                       AND dp.name NOT LIKE N''##%''
                       AND dp.type <> ''R'';';

        BEGIN TRY
            INSERT INTO #HighPriv (ScopeLevel, DatabaseName, PrincipalName, RoleName)
            EXEC sp_executesql @sql, N'@dbname SYSNAME', @dbname = @db;
        END TRY
        BEGIN CATCH
            /* database unreadable or offline mid-scan - skip it */
            SET @Detail = NULL;
        END CATCH

        FETCH NEXT FROM db_cursor INTO @db;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SELECT @ServerCount = SUM(CASE WHEN ScopeLevel = 'Server' THEN 1 ELSE 0 END),
       @DbCount     = SUM(CASE WHEN ScopeLevel = 'Database' THEN 1 ELSE 0 END)
FROM #HighPriv;

SET @ServerCount = ISNULL(@ServerCount, 0);
SET @DbCount = ISNULL(@DbCount, 0);
SET @Total = @ServerCount + @DbCount;

SELECT @Detail = STUFF((
        SELECT N'; ' + x.DatabaseName + N' -> ' + x.PrincipalName + N' [' + x.RoleName + N']'
        FROM (
            SELECT TOP (15) h.ScopeLevel, h.DatabaseName, h.PrincipalName, h.RoleName
            FROM #HighPriv AS h
            ORDER BY h.ScopeLevel, h.DatabaseName, h.RoleName, h.PrincipalName
        ) AS x
        ORDER BY x.ScopeLevel, x.DatabaseName, x.RoleName, x.PrincipalName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

SET @Detail = ISNULL(@Detail, N'none');

SET @Score = CASE
                WHEN @Total = 0 THEN 3
                WHEN @Total BETWEEN 1 AND 3 THEN 2
                WHEN @Total BETWEEN 4 AND 8 THEN 1
                ELSE 0
             END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding =
      N'Scope: ' + CASE WHEN @IsAzureSqlDb = 1 THEN N'Azure SQL Database (current database only)'
                        ELSE N'server-wide (' + CONVERT(NVARCHAR(10), @DbScanned) + N' user database(s) scanned)' END
    + N'. High-privilege principals found: ' + CONVERT(NVARCHAR(10), @Total)
    + N' (server-level sysadmin/securityadmin/serveradmin: ' + CONVERT(NVARCHAR(10), @ServerCount)
    + N', database-level db_owner/db_securityadmin/db_accessadmin: ' + CONVERT(NVARCHAR(10), @DbCount) + N')'
    + N'. System principals (sa, ##MS_%, NT SERVICE\%, NT AUTHORITY\%, dbo, guest) and disabled logins are excluded. '
    + CASE WHEN @Total = 0
           THEN N'No non-system principal holds a broad administrative role; least privilege is applied.'
           ELSE N'Members (first 15): ' + @Detail + N'.'
      END;

IF OBJECT_ID('tempdb..#HighPriv') IS NOT NULL DROP TABLE #HighPriv;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;