/* Checklist 6.1.4 - Application connects via a dedicated least-privilege service account/identity (Managed Identity preferred)
   Read-only diagnostic. Scope: SERVER. */
SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @DatabaseQueried NVARCHAR(256);
DECLARE @Result NVARCHAR(50);
DECLARE @Score INT;
DECLARE @Finding NVARCHAR(4000);

SET @DatabaseQueried = CASE
                            WHEN @EngineEdition = 5 THEN DB_NAME()
                            ELSE ISNULL(CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(256)), CAST(@@SERVERNAME AS NVARCHAR(256)))
                       END;

DECLARE @Principals TABLE
(
    PrincipalName      NVARCHAR(256) NOT NULL,
    PrincipalType      NVARCHAR(60)  NOT NULL,
    IsExternalIdentity BIT           NOT NULL,
    IsHighPrivilege    BIT           NOT NULL,
    IsDisabled         BIT           NOT NULL
);

IF @EngineEdition = 5
BEGIN
    /* Azure SQL Database - the connecting identities are contained database principals */
    INSERT INTO @Principals (PrincipalName, PrincipalType, IsExternalIdentity, IsHighPrivilege, IsDisabled)
    SELECT dp.name,
           dp.type_desc,
           CASE WHEN dp.type IN ('E', 'X') THEN 1 ELSE 0 END,
           CASE WHEN ISNULL(IS_ROLEMEMBER('db_owner', dp.name), 0) = 1
                   OR ISNULL(IS_ROLEMEMBER('db_securityadmin', dp.name), 0) = 1
                   OR ISNULL(IS_ROLEMEMBER('db_accessadmin', dp.name), 0) = 1
                   OR ISNULL(IS_ROLEMEMBER('db_ddladmin', dp.name), 0) = 1
                THEN 1 ELSE 0 END,
           0
    FROM sys.database_principals AS dp
    WHERE dp.type IN ('S', 'E', 'X')
      AND dp.sid IS NOT NULL
      AND dp.is_fixed_role = 0
      AND dp.name NOT IN ('guest', 'dbo', 'INFORMATION_SCHEMA', 'sys', 'public')
      AND dp.name NOT LIKE '##%';
END
ELSE
BEGIN
    /* SQL Server / Azure SQL Managed Instance - server level logins.
       Elevated explicit server permissions also disqualify a principal from "least privilege". */
    INSERT INTO @Principals (PrincipalName, PrincipalType, IsExternalIdentity, IsHighPrivilege, IsDisabled)
    SELECT sp.name,
           sp.type_desc,
           CASE WHEN sp.type IN ('E', 'X') THEN 1 ELSE 0 END,
           CASE WHEN ISNULL(IS_SRVROLEMEMBER('sysadmin', sp.name), 0) = 1
                   OR ISNULL(IS_SRVROLEMEMBER('securityadmin', sp.name), 0) = 1
                   OR ISNULL(IS_SRVROLEMEMBER('serveradmin', sp.name), 0) = 1
                   OR EXISTS (SELECT 1
                              FROM sys.server_permissions AS perm
                              WHERE perm.grantee_principal_id = sp.principal_id
                                AND perm.permission_name IN ('CONTROL SERVER', 'ALTER ANY LOGIN', 'IMPERSONATE ANY LOGIN')
                                AND perm.state IN ('G', 'W'))
                THEN 1 ELSE 0 END,
           CASE WHEN sp.is_disabled = 1 THEN 1 ELSE 0 END
    FROM sys.server_principals AS sp
    WHERE sp.type IN ('S', 'U', 'G', 'E', 'X')
      AND sp.name <> 'sa'
      AND sp.name NOT LIKE '##%'
      AND sp.name NOT LIKE 'NT SERVICE\%'
      AND sp.name NOT LIKE 'NT AUTHORITY\%'
      AND sp.name NOT LIKE 'BUILTIN\%';
END

DECLARE @TotalPrincipals        INT = 0;
DECLARE @LeastPrivCount         INT = 0;
DECLARE @ExternalLeastPrivCount INT = 0;
DECLARE @HighPrivCount          INT = 0;

SELECT @TotalPrincipals        = COUNT(*),
       @LeastPrivCount         = SUM(CASE WHEN IsHighPrivilege = 0 AND IsDisabled = 0 THEN 1 ELSE 0 END),
       @ExternalLeastPrivCount = SUM(CASE WHEN IsHighPrivilege = 0 AND IsDisabled = 0 AND IsExternalIdentity = 1 THEN 1 ELSE 0 END),
       @HighPrivCount          = SUM(CASE WHEN IsHighPrivilege = 1 AND IsDisabled = 0 THEN 1 ELSE 0 END)
FROM @Principals;

SET @TotalPrincipals        = ISNULL(@TotalPrincipals, 0);
SET @LeastPrivCount         = ISNULL(@LeastPrivCount, 0);
SET @ExternalLeastPrivCount = ISNULL(@ExternalLeastPrivCount, 0);
SET @HighPrivCount          = ISNULL(@HighPrivCount, 0);

/* Supporting evidence: how current application connections are actually authenticated */
DECLARE @AppSessions INT = -1;
DECLARE @ElevatedAppSessions INT = -1;

BEGIN TRY
    SELECT @AppSessions = COUNT(*),
           @ElevatedAppSessions = SUM(CASE WHEN ISNULL(IS_SRVROLEMEMBER('sysadmin', s.login_name), 0) = 1 THEN 1 ELSE 0 END)
    FROM sys.dm_exec_sessions AS s
    WHERE s.is_user_process = 1
      AND s.session_id <> @@SPID
      AND ISNULL(s.program_name, '') NOT LIKE 'Microsoft SQL Server Management Studio%'
      AND ISNULL(s.program_name, '') NOT LIKE 'azdata%'
      AND ISNULL(s.program_name, '') NOT LIKE 'SQLAgent%';
END TRY
BEGIN CATCH
    SET @AppSessions = -1;
    SET @ElevatedAppSessions = -1;
END CATCH

DECLARE @LeastPrivNames NVARCHAR(1500) = N'';
DECLARE @HighPrivNames  NVARCHAR(1000) = N'';

SELECT @LeastPrivNames = @LeastPrivNames + x.PrincipalName + N' (' + x.PrincipalType + N'); '
FROM (SELECT TOP (5) PrincipalName, PrincipalType, IsExternalIdentity
      FROM @Principals
      WHERE IsHighPrivilege = 0 AND IsDisabled = 0
      ORDER BY IsExternalIdentity DESC, PrincipalName) AS x;

SELECT @HighPrivNames = @HighPrivNames + y.PrincipalName + N'; '
FROM (SELECT TOP (5) PrincipalName
      FROM @Principals
      WHERE IsHighPrivilege = 1 AND IsDisabled = 0
      ORDER BY PrincipalName) AS y;

IF @ExternalLeastPrivCount >= 1 AND @HighPrivCount = 0
    SET @Score = 3;
ELSE IF (@ExternalLeastPrivCount >= 1 AND @HighPrivCount > 0)
     OR (@ExternalLeastPrivCount = 0 AND @LeastPrivCount >= 1 AND @HighPrivCount = 0)
    SET @Score = 2;
ELSE IF @LeastPrivCount >= 1
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding = N'Non-system connecting principals: ' + CAST(@TotalPrincipals AS NVARCHAR(10))
             + N'. Enabled least-privilege principals: ' + CAST(@LeastPrivCount AS NVARCHAR(10))
             + N' (external Azure AD / Managed Identity: ' + CAST(@ExternalLeastPrivCount AS NVARCHAR(10)) + N')'
             + N'. Enabled principals holding elevated server privileges (sysadmin/securityadmin/serveradmin or CONTROL SERVER / ALTER ANY LOGIN / IMPERSONATE ANY LOGIN): ' + CAST(@HighPrivCount AS NVARCHAR(10)) + N'. '
             + CASE WHEN LEN(@LeastPrivNames) > 0 THEN N'Least-privilege sample: ' + @LeastPrivNames ELSE N'' END
             + CASE WHEN LEN(@HighPrivNames) > 0 THEN N'Elevated sample: ' + @HighPrivNames ELSE N'' END
             + CASE WHEN @AppSessions >= 0
                    THEN N'Current non-tool user sessions: ' + CAST(@AppSessions AS NVARCHAR(10))
                         + N', of which connected under a sysadmin login: ' + CAST(ISNULL(@ElevatedAppSessions, 0) AS NVARCHAR(10)) + N'. '
                    ELSE N'Live session evidence unavailable (VIEW SERVER STATE not granted). ' END
             + CASE
                    WHEN @Score = 3 THEN N'At least one dedicated external (Managed Identity / Azure AD) identity is present with least privilege and no non-system principal holds elevated server privileges.'
                    WHEN @Score = 2 AND @ExternalLeastPrivCount >= 1 THEN N'A Managed Identity / Azure AD identity exists, but elevated non-system principals remain available for application connections.'
                    WHEN @Score = 2 THEN N'Dedicated least-privilege identities exist, but they are SQL logins rather than the preferred Managed Identity / Azure AD identity.'
                    WHEN @Score = 1 THEN N'Least-privilege principals exist, but elevated non-system principals are also present and could be used by the application.'
                    ELSE N'No dedicated least-privilege connecting identity was found; applications can only be connecting through sa or an elevated shared account.'
               END;

SELECT @Result           AS Result,
       @Score            AS Score,
       @DatabaseQueried  AS DatabaseQueried,
       @Finding          AS Finding;