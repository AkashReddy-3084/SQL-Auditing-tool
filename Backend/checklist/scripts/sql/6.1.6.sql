/*
    Checklist Item : 6.1.6 - Guest/contractor access explicitly governed and time-bound
    Scope          : SERVER
    Read-only      : queries system catalog views only; no data or configuration is modified.
    Compatibility  : SQL Server 2012+, Azure SQL Managed Instance, Azure SQL Database (single-DB path).
*/
SET NOCOUNT ON;

DECLARE @IsAzureSqlDb BIT = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 5 THEN 1 ELSE 0 END;

DECLARE @Result           NVARCHAR(20);
DECLARE @Score            INT;
DECLARE @DatabaseQueried  NVARCHAR(256);
DECLARE @Finding          NVARCHAR(MAX);

DECLARE @GuestAccess TABLE
(
    DatabaseName    SYSNAME       NOT NULL,
    PermissionState NVARCHAR(60)  NULL
);

DECLARE @ExternalPrincipals TABLE
(
    PrincipalName       SYSNAME      NOT NULL,
    PrincipalType       NVARCHAR(60) NULL,
    IsDisabled          BIT          NOT NULL,
    ExpirationEnforced  BIT          NOT NULL,
    PrincipalScope      NVARCHAR(20) NOT NULL
);

IF @IsAzureSqlDb = 1
BEGIN
    /* Azure SQL Database: cross-database queries are unavailable, inspect the connected database. */
    INSERT INTO @GuestAccess (DatabaseName, PermissionState)
    SELECT DB_NAME(), dp.state_desc
    FROM sys.database_permissions AS dp
    INNER JOIN sys.database_principals AS pr
        ON pr.principal_id = dp.grantee_principal_id
    WHERE pr.name = N'guest'
      AND dp.permission_name = N'CONNECT'
      AND dp.state_desc = N'GRANT'
      AND DB_NAME() NOT IN (N'master', N'tempdb', N'model', N'msdb');

    INSERT INTO @ExternalPrincipals (PrincipalName, PrincipalType, IsDisabled, ExpirationEnforced, PrincipalScope)
    SELECT dpr.name, dpr.type_desc, 0, 0, N'DATABASE'
    FROM sys.database_principals AS dpr
    WHERE dpr.type IN ('S', 'U', 'G', 'E', 'X')
      AND dpr.name <> N'guest'
      AND dpr.name NOT LIKE N'##%'
      AND (   dpr.name LIKE N'%contract%'
           OR dpr.name LIKE N'%vendor%'
           OR dpr.name LIKE N'%consult%'
           OR dpr.name LIKE N'%extern%'
           OR dpr.name LIKE N'%guest%'
           OR dpr.name LIKE N'%temp%'
           OR dpr.name LIKE N'%partner%'
           OR dpr.name LIKE N'%thirdparty%'
           OR dpr.name LIKE N'%3rdparty%'
           OR dpr.name LIKE N'%supplier%');
END
ELSE
BEGIN
    /* SQL Server / Managed Instance: evaluate every accessible user database. */
    DECLARE @DbName SYSNAME;
    DECLARE @Sql    NVARCHAR(MAX);

    DECLARE guest_db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.source_database_id IS NULL
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN guest_db_cursor;
    FETCH NEXT FROM guest_db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Sql = N'SELECT @db, dp.state_desc
                     FROM ' + QUOTENAME(@DbName) + N'.sys.database_permissions AS dp
                     INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.database_principals AS pr
                         ON pr.principal_id = dp.grantee_principal_id
                     WHERE pr.name = N''guest''
                       AND dp.permission_name = N''CONNECT''
                       AND dp.state_desc = N''GRANT'';';

        BEGIN TRY
            INSERT INTO @GuestAccess (DatabaseName, PermissionState)
            EXEC sp_executesql @Sql, N'@db SYSNAME', @db = @DbName;
        END TRY
        BEGIN CATCH
            /* Database became unreadable mid-scan; skip it rather than fail the audit. */
        END CATCH;

        FETCH NEXT FROM guest_db_cursor INTO @DbName;
    END

    CLOSE guest_db_cursor;
    DEALLOCATE guest_db_cursor;

    INSERT INTO @ExternalPrincipals (PrincipalName, PrincipalType, IsDisabled, ExpirationEnforced, PrincipalScope)
    SELECT sp.name,
           sp.type_desc,
           CAST(sp.is_disabled AS BIT),
           CAST(ISNULL(sl.is_expiration_checked, 0) AS BIT),
           N'SERVER'
    FROM sys.server_principals AS sp
    LEFT JOIN sys.sql_logins AS sl
        ON sl.principal_id = sp.principal_id
    WHERE sp.type IN ('S', 'U', 'G', 'E', 'X')
      AND sp.name NOT LIKE N'##%'
      AND sp.name NOT LIKE N'NT SERVICE\%'
      AND sp.name NOT LIKE N'NT AUTHORITY\%'
      AND (   sp.name LIKE N'%contract%'
           OR sp.name LIKE N'%vendor%'
           OR sp.name LIKE N'%consult%'
           OR sp.name LIKE N'%extern%'
           OR sp.name LIKE N'%guest%'
           OR sp.name LIKE N'%temp%'
           OR sp.name LIKE N'%partner%'
           OR sp.name LIKE N'%thirdparty%'
           OR sp.name LIKE N'%3rdparty%'
           OR sp.name LIKE N'%supplier%');
END

DECLARE @GuestGrantCount      INT = (SELECT COUNT(*) FROM @GuestAccess);
DECLARE @ExternalTotal        INT = (SELECT COUNT(*) FROM @ExternalPrincipals);
DECLARE @ExternalEnabled      INT = (SELECT COUNT(*) FROM @ExternalPrincipals WHERE IsDisabled = 0);
DECLARE @ExternalNoExpiration INT = (SELECT COUNT(*) FROM @ExternalPrincipals WHERE IsDisabled = 0 AND ExpirationEnforced = 0);

DECLARE @GuestList NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT N', ' + g.DatabaseName
                  FROM @GuestAccess AS g
                  ORDER BY g.DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'none');

DECLARE @ExternalList NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT TOP (25) N', ' + e.PrincipalName
                        + N' [' + CASE WHEN e.IsDisabled = 1 THEN N'disabled' ELSE N'enabled' END
                        + CASE WHEN e.IsDisabled = 0 AND e.ExpirationEnforced = 0 THEN N', no expiration' ELSE N'' END + N']'
                  FROM @ExternalPrincipals AS e
                  ORDER BY e.IsDisabled, e.PrincipalName
                  FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'none');

SET @DatabaseQueried =
    CASE WHEN @IsAzureSqlDb = 1
         THEN DB_NAME()
         ELSE N'SERVER: ' + CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128)) + N' (all accessible user databases)'
    END;

SET @Result =
    CASE
        WHEN @GuestGrantCount > 0 THEN N'Fail'
        WHEN @ExternalEnabled > 0 THEN N'Partial'
        ELSE N'Pass'
    END;

SET @Score =
    CASE
        WHEN @GuestGrantCount > 0 THEN 1
        WHEN @ExternalEnabled > 0 THEN 2
        ELSE 3
    END;

SET @Finding =
      N'Databases granting CONNECT to the guest user: ' + CAST(@GuestGrantCount AS NVARCHAR(10))
    + N' (' + @GuestList + N'). '
    + N'External/contractor-named principals found: ' + CAST(@ExternalTotal AS NVARCHAR(10))
    + N' (enabled: ' + CAST(@ExternalEnabled AS NVARCHAR(10))
    + N', enabled without password-expiration enforcement: ' + CAST(@ExternalNoExpiration AS NVARCHAR(10))
    + N') -> ' + @ExternalList + N'. '
    + CASE
        WHEN @GuestGrantCount > 0
            THEN N'The guest user can connect to user databases, so anonymous/unmapped access exists that is neither governed nor time-bound.'
        WHEN @ExternalEnabled > 0
            THEN N'Guest access is correctly revoked, but enabled external/contractor-style principals exist with no native expiry control; contract end-dates must be corroborated from access records.'
        ELSE N'Guest access is revoked in all user databases and no external/contractor-style principals are present.'
      END
    + N' SQL Server stores no account end-date attribute, so the time-bound clause is evidenced only by expiration enforcement and the absence of standing external accounts.';

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;