/* Checklist 6.1.8 - Schema/object-level permissions align with least privilege
   Read-only: writes only to session temp tables. */
SET NOCOUNT ON;

DECLARE @EngineEdition int = CAST(SERVERPROPERTY('EngineEdition') AS int);

IF OBJECT_ID('tempdb..#Findings') IS NOT NULL DROP TABLE #Findings;
CREATE TABLE #Findings
(
    DatabaseName   sysname,
    PermClass      nvarchar(10),
    SecurableName  nvarchar(600),
    PermissionName nvarchar(128),
    StateDesc      nvarchar(60),
    GranteeName    sysname,
    IssueType      nvarchar(40)
);

IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;
CREATE TABLE #Dbs (DatabaseName sysname);

IF OBJECT_ID('tempdb..#Skipped') IS NOT NULL DROP TABLE #Skipped;
CREATE TABLE #Skipped (DatabaseName sysname, ErrorMessage nvarchar(2048));

IF @EngineEdition = 5   /* Azure SQL Database: cross-database execution is not supported */
    INSERT INTO #Dbs (DatabaseName) VALUES (DB_NAME());
ELSE
    INSERT INTO #Dbs (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.is_in_standby = 0
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1;

DECLARE @db sysname, @execSp nvarchar(400), @stmt nvarchar(max);

SET @stmt = N'
INSERT INTO #Findings (DatabaseName, PermClass, SecurableName, PermissionName, StateDesc, GranteeName, IssueType)
SELECT @dbn,
       N''SCHEMA'',
       QUOTENAME(s.name),
       dp.permission_name,
       dp.state_desc,
       pr.name,
       CASE
            WHEN pr.name IN (N''public'', N''guest'')                       THEN N''GrantToPublicOrGuest''
            WHEN dp.state_desc = N''GRANT_WITH_GRANT_OPTION''               THEN N''GrantWithGrantOption''
            WHEN dp.permission_name IN (N''CONTROL'', N''TAKE OWNERSHIP'')  THEN N''ControlOrOwnership''
            ELSE N''AlterOrImpersonate''
       END
FROM sys.database_permissions AS dp
JOIN sys.database_principals AS pr ON pr.principal_id = dp.grantee_principal_id
JOIN sys.schemas            AS s  ON s.schema_id     = dp.major_id
WHERE dp.class = 3
  AND dp.state IN (''G'', ''W'')
  AND s.name NOT IN (N''sys'', N''INFORMATION_SCHEMA'')
  AND s.schema_id NOT BETWEEN 16384 AND 16399
  AND pr.name <> N''dbo''
  AND pr.is_fixed_role = 0
  AND (    pr.name IN (N''public'', N''guest'')
        OR dp.state_desc = N''GRANT_WITH_GRANT_OPTION''
        OR dp.permission_name IN (N''CONTROL'', N''TAKE OWNERSHIP'', N''ALTER'', N''ALTER ANY SCHEMA'', N''IMPERSONATE'') );

INSERT INTO #Findings (DatabaseName, PermClass, SecurableName, PermissionName, StateDesc, GranteeName, IssueType)
SELECT @dbn,
       N''OBJECT'',
       QUOTENAME(SCHEMA_NAME(o.schema_id)) + N''.'' + QUOTENAME(o.name),
       dp.permission_name,
       dp.state_desc,
       pr.name,
       CASE
            WHEN pr.name IN (N''public'', N''guest'')                       THEN N''GrantToPublicOrGuest''
            WHEN dp.state_desc = N''GRANT_WITH_GRANT_OPTION''               THEN N''GrantWithGrantOption''
            WHEN dp.permission_name IN (N''CONTROL'', N''TAKE OWNERSHIP'')  THEN N''ControlOrOwnership''
            ELSE N''AlterOrImpersonate''
       END
FROM sys.database_permissions AS dp
JOIN sys.database_principals AS pr ON pr.principal_id = dp.grantee_principal_id
JOIN sys.objects            AS o  ON o.object_id     = dp.major_id
WHERE dp.class = 1
  AND dp.state IN (''G'', ''W'')
  AND o.is_ms_shipped = 0
  AND pr.name <> N''dbo''
  AND pr.is_fixed_role = 0
  AND (    pr.name IN (N''public'', N''guest'')
        OR dp.state_desc = N''GRANT_WITH_GRANT_OPTION''
        OR dp.permission_name IN (N''CONTROL'', N''TAKE OWNERSHIP'', N''ALTER'', N''IMPERSONATE'') );
';

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR SELECT DatabaseName FROM #Dbs ORDER BY DatabaseName;
OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        IF @EngineEdition = 5
            EXEC sys.sp_executesql @stmt, N'@dbn sysname', @dbn = @db;
        ELSE
        BEGIN
            SET @execSp = QUOTENAME(@db) + N'.sys.sp_executesql';
            EXEC @execSp @stmt, N'@dbn sysname', @dbn = @db;
        END
    END TRY
    BEGIN CATCH
        INSERT INTO #Skipped (DatabaseName, ErrorMessage) VALUES (@db, LEFT(ERROR_MESSAGE(), 2048));
    END CATCH

    FETCH NEXT FROM db_cur INTO @db;
END
CLOSE db_cur;
DEALLOCATE db_cur;

DECLARE @DbCount        int = (SELECT COUNT(*) FROM #Dbs),
        @SkippedCount   int = (SELECT COUNT(*) FROM #Skipped),
        @TotalIssues    int = (SELECT COUNT(*) FROM #Findings),
        @PublicIssues   int = (SELECT COUNT(*) FROM #Findings WHERE IssueType = N'GrantToPublicOrGuest'),
        @ControlIssues  int = (SELECT COUNT(*) FROM #Findings WHERE IssueType = N'ControlOrOwnership'),
        @GrantOptIssues int = (SELECT COUNT(*) FROM #Findings WHERE IssueType = N'GrantWithGrantOption'),
        @AlterIssues    int = (SELECT COUNT(*) FROM #Findings WHERE IssueType = N'AlterOrImpersonate'),
        @AffectedDbs    int = (SELECT COUNT(DISTINCT DatabaseName) FROM #Findings);

DECLARE @DatabaseQueried nvarchar(max) =
    ISNULL(STUFF((SELECT N', ' + d.DatabaseName
                  FROM #Dbs AS d
                  ORDER BY d.DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'None');

DECLARE @Examples nvarchar(max) =
    ISNULL(STUFF((SELECT N'; ' + f.DatabaseName + N': ' + f.PermissionName + N' (' + f.StateDesc + N') on '
                         + f.PermClass + N' ' + f.SecurableName + N' -> ' + f.GranteeName
                  FROM (SELECT TOP (10) f2.* FROM #Findings AS f2
                        ORDER BY CASE f2.IssueType
                                      WHEN N'GrantToPublicOrGuest' THEN 1
                                      WHEN N'ControlOrOwnership'   THEN 2
                                      WHEN N'GrantWithGrantOption' THEN 3
                                      ELSE 4 END,
                                 f2.DatabaseName, f2.SecurableName) AS f
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'');

DECLARE @Result nvarchar(20), @Score int, @Finding nvarchar(max);

IF @DbCount = 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'No accessible user database could be enumerated, so schema/object-level permissions could not be assessed. Verify the audit login has CONNECT and VIEW DEFINITION rights on the target databases.';
END
ELSE IF @TotalIssues = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'No over-permissive schema-level or object-level grants found across ' + CAST(@DbCount AS nvarchar(10))
                 + N' user database(s). No grants to public or guest, no CONTROL/TAKE OWNERSHIP grants, no WITH GRANT OPTION delegation and no ALTER/IMPERSONATE grants outside dbo and fixed database roles.';
END
ELSE IF @PublicIssues > 0 OR @ControlIssues > 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'Least privilege breached: ' + CAST(@TotalIssues AS nvarchar(10)) + N' over-permissive grant(s) across '
                 + CAST(@AffectedDbs AS nvarchar(10)) + N' of ' + CAST(@DbCount AS nvarchar(10)) + N' user database(s) - '
                 + CAST(@PublicIssues AS nvarchar(10)) + N' to public/guest, '
                 + CAST(@ControlIssues AS nvarchar(10)) + N' CONTROL/TAKE OWNERSHIP, '
                 + CAST(@GrantOptIssues AS nvarchar(10)) + N' WITH GRANT OPTION, '
                 + CAST(@AlterIssues AS nvarchar(10)) + N' ALTER/IMPERSONATE. Examples: ' + @Examples;
END
ELSE
BEGIN
    SET @Score = 2;
    SET @Finding = N'Partial compliance: no grants to public/guest and no CONTROL/TAKE OWNERSHIP, but '
                 + CAST(@TotalIssues AS nvarchar(10)) + N' elevated grant(s) across ' + CAST(@AffectedDbs AS nvarchar(10))
                 + N' of ' + CAST(@DbCount AS nvarchar(10)) + N' user database(s) - '
                 + CAST(@GrantOptIssues AS nvarchar(10)) + N' WITH GRANT OPTION, '
                 + CAST(@AlterIssues AS nvarchar(10)) + N' ALTER/IMPERSONATE. Examples: ' + @Examples;
END

IF @SkippedCount > 0
    SET @Finding = @Finding + N' NOTE: ' + CAST(@SkippedCount AS nvarchar(10))
                 + N' database(s) could not be inspected due to access errors and are excluded from this result.';

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result                       AS Result,
       @Score                        AS Score,
       LEFT(@DatabaseQueried, 4000)  AS DatabaseQueried,
       LEFT(@Finding, 4000)          AS Finding;