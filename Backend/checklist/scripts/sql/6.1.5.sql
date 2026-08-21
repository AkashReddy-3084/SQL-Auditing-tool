SET NOCOUNT ON;

-- Checklist 6.1.5 - No shared/generic accounts for administrative or application access
-- Read-only: enumerates principals whose names match shared/generic patterns and reports their privilege level.

DECLARE @IsAzureSqlDb      BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @Sql               NVARCHAR(MAX);
DECLARE @Predicate         NVARCHAR(MAX);
DECLARE @TotalGeneric      INT = 0;
DECLARE @EnabledGeneric    INT = 0;
DECLARE @ElevatedGeneric   INT = 0;
DECLARE @SaEnabled         INT = 0;
DECLARE @EnabledList       NVARCHAR(MAX) = N'';
DECLARE @ElevatedList      NVARCHAR(MAX) = N'';
DECLARE @Result            NVARCHAR(20);
DECLARE @Score             INT;
DECLARE @Finding           NVARCHAR(MAX);
DECLARE @ScopeLabel        NVARCHAR(60);

IF OBJECT_ID('tempdb..#GenericAccounts') IS NOT NULL
    DROP TABLE #GenericAccounts;

CREATE TABLE #GenericAccounts
(
    AccountName SYSNAME       NOT NULL,
    AccountType NVARCHAR(60)  NULL,
    IsDisabled  BIT           NOT NULL,
    IsElevated  BIT           NOT NULL
);

SET @Predicate = N'(
           LOWER(p.name) = ''sa''
        OR LOWER(p.name) LIKE ''%admin%''
        OR LOWER(p.name) LIKE ''%shared%''
        OR LOWER(p.name) LIKE ''%generic%''
        OR LOWER(p.name) LIKE ''%common%''
        OR LOWER(p.name) LIKE ''%service%''
        OR LOWER(p.name) LIKE ''%svc%''
        OR LOWER(p.name) LIKE ''%test%''
        OR LOWER(p.name) LIKE ''%temp%''
        OR LOWER(p.name) LIKE ''%support%''
        OR LOWER(p.name) IN (''app'', ''apps'', ''appuser'', ''application'', ''user'', ''users'',
                             ''demo'', ''dba'', ''sql'', ''sqluser'', ''operator'', ''developer'',
                             ''dev'', ''team'', ''etl'', ''batch'', ''job'', ''report'', ''reporting'',
                             ''readonly'', ''readwrite'', ''backup'', ''monitor'', ''client'',
                             ''vendor'', ''contractor'', ''staff'', ''guest'')
      )';

IF @IsAzureSqlDb = 1
BEGIN
    SET @ScopeLabel = N'Azure SQL Database (database principals)';
    SET @Sql = N'
        SELECT p.name,
               p.type_desc,
               CAST(0 AS BIT),
               CAST(CASE WHEN ISNULL(IS_ROLEMEMBER(''db_owner'', p.name), 0) = 1
                          OR ISNULL(IS_ROLEMEMBER(''db_securityadmin'', p.name), 0) = 1
                          OR ISNULL(IS_ROLEMEMBER(''db_accessadmin'', p.name), 0) = 1
                         THEN 1 ELSE 0 END AS BIT)
        FROM sys.database_principals AS p
        WHERE p.type IN (''S'', ''U'', ''G'', ''X'', ''E'')
          AND p.is_fixed_role = 0
          AND p.name NOT IN (''dbo'', ''sys'', ''INFORMATION_SCHEMA'', ''public'')
          AND p.name NOT LIKE ''##%''
          AND ' + @Predicate + N';';
END
ELSE
BEGIN
    SET @ScopeLabel = N'SQL Server instance (server principals)';
    SET @Sql = N'
        SELECT p.name,
               p.type_desc,
               CAST(CASE WHEN p.is_disabled = 1 THEN 1 ELSE 0 END AS BIT),
               CAST(CASE WHEN ISNULL(IS_SRVROLEMEMBER(''sysadmin'', p.name), 0) = 1
                          OR ISNULL(IS_SRVROLEMEMBER(''securityadmin'', p.name), 0) = 1
                          OR ISNULL(IS_SRVROLEMEMBER(''serveradmin'', p.name), 0) = 1
                          OR EXISTS (SELECT 1
                                     FROM sys.server_permissions AS perm
                                     WHERE perm.grantee_principal_id = p.principal_id
                                       AND perm.permission_name = ''CONTROL SERVER''
                                       AND perm.state IN (''G'', ''W''))
                         THEN 1 ELSE 0 END AS BIT)
        FROM sys.server_principals AS p
        WHERE p.type IN (''S'', ''U'', ''G'')
          AND p.is_fixed_role = 0
          AND p.name NOT LIKE ''##%''
          AND LOWER(p.name) NOT LIKE ''nt authority%''
          AND LOWER(p.name) NOT LIKE ''nt service%''
          AND p.name <> ''distributor_admin''
          AND ' + @Predicate + N';';
END

BEGIN TRY
    INSERT INTO #GenericAccounts (AccountName, AccountType, IsDisabled, IsElevated)
    EXEC sys.sp_executesql @Sql;
END TRY
BEGIN CATCH
    SET @ScopeLabel = N'Enumeration error';
END CATCH

SELECT @TotalGeneric    = COUNT(*),
       @EnabledGeneric  = SUM(CASE WHEN IsDisabled = 0 THEN 1 ELSE 0 END),
       @ElevatedGeneric = SUM(CASE WHEN IsDisabled = 0 AND IsElevated = 1 THEN 1 ELSE 0 END)
FROM #GenericAccounts;

SET @TotalGeneric    = ISNULL(@TotalGeneric, 0);
SET @EnabledGeneric  = ISNULL(@EnabledGeneric, 0);
SET @ElevatedGeneric = ISNULL(@ElevatedGeneric, 0);

SELECT @SaEnabled = COUNT(*)
FROM #GenericAccounts
WHERE LOWER(AccountName) = N'sa'
  AND IsDisabled = 0;

SET @SaEnabled = ISNULL(@SaEnabled, 0);

SET @EnabledList = ISNULL(STUFF((SELECT TOP (25) N', ' + g.AccountName + N' (' + ISNULL(g.AccountType, N'UNKNOWN') + N')'
                                 FROM #GenericAccounts AS g
                                 WHERE g.IsDisabled = 0
                                 ORDER BY g.IsElevated DESC, g.AccountName
                                 FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'none');

SET @ElevatedList = ISNULL(STUFF((SELECT TOP (25) N', ' + g.AccountName
                                  FROM #GenericAccounts AS g
                                  WHERE g.IsDisabled = 0 AND g.IsElevated = 1
                                  ORDER BY g.AccountName
                                  FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'none');

SET @Score = CASE
                WHEN @SaEnabled > 0 OR @ElevatedGeneric > 0 THEN 1
                WHEN @EnabledGeneric > 0 THEN 2
                ELSE 3
             END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding =
      N'Scope: ' + @ScopeLabel
    + N'. Principals matching shared/generic naming patterns: ' + CAST(@TotalGeneric AS NVARCHAR(10))
    + N' (enabled: ' + CAST(@EnabledGeneric AS NVARCHAR(10))
    + N', enabled with elevated rights: ' + CAST(@ElevatedGeneric AS NVARCHAR(10))
    + N', built-in ''sa'' enabled: ' + CASE WHEN @SaEnabled > 0 THEN N'YES' ELSE N'NO' END + N'). '
    + CASE
        WHEN @Score = 3 THEN N'No enabled shared/generic-named principal was found; administrative and application access appears to use named identities.'
        WHEN @Score = 2 THEN N'Enabled generic-named principals found, none holding elevated rights: ' + @EnabledList + N'.'
        ELSE N'Enabled generic-named principals with elevated rights: ' + @ElevatedList
             + N'. All enabled generic-named principals: ' + @EnabledList + N'.'
      END
    + N' Naming patterns are a proxy for account sharing; confirm ownership of the listed accounts against the identity register.';

SELECT @Result AS Result,
       @Score  AS Score,
       CASE WHEN @IsAzureSqlDb = 1 THEN DB_NAME() ELSE N'master' END AS DatabaseQueried,
       @Finding AS Finding;

IF OBJECT_ID('tempdb..#GenericAccounts') IS NOT NULL
    DROP TABLE #GenericAccounts;