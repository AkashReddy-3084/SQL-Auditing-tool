-- Checklist: Production access restricted (no developer write/deploy)
-- Scope: DATABASE
-- Scoring: 0: Fail - Developer accounts/roles with write/deploy permissions found. 1: Partial Pass - Developer accounts found but restricted to read-only. 2: Mostly Pass - No developer accounts found, but some accounts with broad permissions exist. 3: Pass - No developer accounts found with write/deploy permissions.

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name
FROM sys.databases
WHERE database_id > 4
  AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @DevWrite NVARCHAR(MAX) = NULL;
        DECLARE @DevRead NVARCHAR(MAX) = NULL;
        DECLARE @BroadPerms NVARCHAR(MAX) = NULL;

        SELECT @DevWrite = STRING_AGG(name, '' '')
        FROM (
            SELECT DISTINCT p.name
            FROM sys.database_principals p
            WHERE p.type IN (''S'', ''U'', ''G'')
              AND (p.name LIKE ''%dev%'' OR p.name LIKE ''%developer%'' OR p.name LIKE ''%test%'' OR p.name LIKE ''%qa%'')
              AND (
                  EXISTS (SELECT 1 FROM sys.database_role_members rm JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id WHERE rm.member_principal_id = p.principal_id AND r.name = ''db_owner'')
                  OR EXISTS (SELECT 1 FROM sys.database_permissions dp WHERE dp.grantee_principal_id = p.principal_id AND dp.state IN (''G'', ''W'') AND dp.permission_name IN (''ALTER'', ''CONTROL'', ''INSERT'', ''UPDATE'', ''DELETE''))
              )
        ) AS t;

        SELECT @DevRead = STRING_AGG(name, '' '')
        FROM (
            SELECT DISTINCT p.name
            FROM sys.database_principals p
            WHERE p.type IN (''S'', ''U'', ''G'')
              AND (p.name LIKE ''%dev%'' OR p.name LIKE ''%developer%'' OR p.name LIKE ''%test%'' OR p.name LIKE ''%qa%'')
              AND NOT EXISTS (SELECT 1 FROM sys.database_role_members rm JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id WHERE rm.member_principal_id = p.principal_id AND r.name = ''db_owner'')
              AND NOT EXISTS (SELECT 1 FROM sys.database_permissions dp WHERE dp.grantee_principal_id = p.principal_id AND dp.state IN (''G'', ''W'') AND dp.permission_name IN (''ALTER'', ''CONTROL'', ''INSERT'', ''UPDATE'', ''DELETE''))
              AND EXISTS (SELECT 1 FROM sys.database_permissions dp WHERE dp.grantee_principal_id = p.principal_id AND dp.state IN (''G'', ''W'') AND dp.permission_name IN (''SELECT'', ''VIEW DEFINITION''))
        ) AS t;

        SELECT @BroadPerms = STRING_AGG(name, '' '')
        FROM (
            SELECT DISTINCT p.name
            FROM sys.database_principals p
            WHERE p.type IN (''S'', ''U'', ''G'')
              AND NOT (p.name LIKE ''%dev%'' OR p.name LIKE ''%developer%'' OR p.name LIKE ''%test%'' OR p.name LIKE ''%qa%'')
              AND EXISTS (SELECT 1 FROM sys.database_role_members rm JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id WHERE rm.member_principal_id = p.principal_id AND r.name IN (''db_owner'', ''db_ddladmin'', ''db_securityadmin''))
        ) AS t;

        DECLARE @DbScore INT;
        DECLARE @DbFinding NVARCHAR(MAX);

        IF @DevWrite IS NOT NULL
        BEGIN
            SET @DbScore = 0;
            SET @DbFinding = ''Developer accounts with write/deploy access: '' + @DevWrite;
        END
        ELSE IF @DevRead IS NOT NULL
        BEGIN
            SET @DbScore = 1;
            SET @DbFinding = ''Developer accounts with read-only access: '' + @DevRead;
        END
        ELSE IF @BroadPerms IS NOT NULL
        BEGIN
            SET @DbScore = 2;
            SET @DbFinding = ''No developer accounts found. Accounts with broad permissions: '' + @BroadPerms;
        END
        ELSE
        BEGIN
            SET @DbScore = 3;
            SET @DbFinding = ''No developer accounts found with write/deploy permissions.'';
        END

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
        ';

        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@DbName, 0, 'Database evaluation failed');
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @DatabaseQueried = (
    SELECT STRING_AGG(DbName, ', ')
    FROM #DbResults
);

SET @Score = ISNULL(
    (SELECT MIN(DbScore) FROM #DbResults),
    0
);

SET @Finding = ISNULL(
    (
        SELECT STRING_AGG(DbName + ': ' + Finding, '; ')
        FROM #DbResults
        WHERE Finding IS NOT NULL
          AND Finding <> ''
    ),
    'No non-compliant findings found'
);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;