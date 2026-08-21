/* Checklist 6.4.3 - Managed Identity used for service-to-service auth where supported */
/* Read-only. Returns a single row: Result, Score, DatabaseQueried, Finding.          */
SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @IsAzureSqlDb BIT = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 5 THEN 1 ELSE 0 END;
DECLARE @MajorVersion INT =
    ISNULL(TRY_CAST(SERVERPROPERTY('ProductMajorVersion') AS INT),
           TRY_CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(64)), 4) AS INT));
/* Database scoped credentials / external data sources exist on SQL 2016+ and all Azure editions. */
DECLARE @SupportsDbScoped BIT = CASE WHEN @IsAzureSqlDb = 1 OR @EngineEdition IN (6, 8, 9, 11) OR ISNULL(@MajorVersion, 0) >= 13 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;
IF OBJECT_ID('tempdb..#Artifacts') IS NOT NULL DROP TABLE #Artifacts;

CREATE TABLE #Dbs (DatabaseName SYSNAME NOT NULL PRIMARY KEY);

CREATE TABLE #Artifacts
(
    DatabaseName        SYSNAME       NOT NULL,
    ArtifactScope       NVARCHAR(20)  NOT NULL,
    ArtifactType        NVARCHAR(60)  NOT NULL,
    ArtifactName        NVARCHAR(256) NOT NULL,
    IdentityValue       NVARCHAR(512) NULL,
    UsesManagedIdentity BIT           NOT NULL,
    InScopeForMI        BIT           NOT NULL
);

/* ---------- 1. Databases in scope ---------- */
IF @IsAzureSqlDb = 1
    INSERT INTO #Dbs (DatabaseName) VALUES (DB_NAME());
ELSE
    INSERT INTO #Dbs (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.state_desc = N'ONLINE'
      AND d.database_id <> 2                 /* tempdb */
      AND d.source_database_id IS NULL       /* skip snapshots */
      AND HAS_DBACCESS(d.name) = 1;

/* ---------- 2. Database scoped artifacts ---------- */
DECLARE @Body NVARCHAR(MAX) = N'
INSERT INTO #Artifacts (DatabaseName, ArtifactScope, ArtifactType, ArtifactName, IdentityValue, UsesManagedIdentity, InScopeForMI)
SELECT DB_NAME(), N''Database'', N''Database Scoped Credential'',
       CONVERT(NVARCHAR(256), c.name),
       CONVERT(NVARCHAR(512), ISNULL(c.credential_identity, N''(none)'')),
       CASE WHEN c.credential_identity LIKE N''%Managed Identity%''
              OR c.credential_identity LIKE N''%Managed Service Identity%''
              OR c.credential_identity LIKE N''%$'' THEN 1 ELSE 0 END,
       1
FROM sys.database_scoped_credentials AS c;

INSERT INTO #Artifacts (DatabaseName, ArtifactScope, ArtifactType, ArtifactName, IdentityValue, UsesManagedIdentity, InScopeForMI)
SELECT DB_NAME(), N''Database'', N''External Data Source'',
       CONVERT(NVARCHAR(256), e.name),
       CONVERT(NVARCHAR(512), ISNULL(c.credential_identity, N''(no credential bound)'')),
       CASE WHEN c.credential_identity LIKE N''%Managed Identity%''
              OR c.credential_identity LIKE N''%Managed Service Identity%''
              OR c.credential_identity LIKE N''%$'' THEN 1 ELSE 0 END,
       CASE WHEN ISNULL(e.credential_id, 0) = 0 THEN 0 ELSE 1 END
FROM sys.external_data_sources AS e
LEFT JOIN sys.database_scoped_credentials AS c
       ON c.credential_id = e.credential_id;

INSERT INTO #Artifacts (DatabaseName, ArtifactScope, ArtifactType, ArtifactName, IdentityValue, UsesManagedIdentity, InScopeForMI)
SELECT DB_NAME(), N''Database'', N''Entra ID Database Principal'',
       CONVERT(NVARCHAR(256), p.name),
       CONVERT(NVARCHAR(512), p.type_desc),
       1,
       0
FROM sys.database_principals AS p
WHERE p.type IN (''E'', ''X'');
';

IF @SupportsDbScoped = 1
BEGIN
    IF @IsAzureSqlDb = 1
    BEGIN
        BEGIN TRY
            EXEC sys.sp_executesql @Body;
        END TRY
        BEGIN CATCH
            /* current database not readable - reflected in the artifact counts */
        END CATCH
    END
    ELSE
    BEGIN
        DECLARE @Db SYSNAME, @Stmt NVARCHAR(MAX);

        DECLARE @Remaining TABLE (DatabaseName SYSNAME NOT NULL);
        INSERT INTO @Remaining (DatabaseName) SELECT DatabaseName FROM #Dbs;

        WHILE EXISTS (SELECT 1 FROM @Remaining)
        BEGIN
            SELECT TOP (1) @Db = DatabaseName FROM @Remaining ORDER BY DatabaseName;
            DELETE FROM @Remaining WHERE DatabaseName = @Db;

            SET @Stmt = N'USE ' + QUOTENAME(@Db) + N'; ' + @Body;

            BEGIN TRY
                EXEC sys.sp_executesql @Stmt;
            END TRY
            BEGIN CATCH
                /* database unreadable at this moment - skip it and continue */
            END CATCH
        END
    END
END

/* ---------- 3. Server scoped artifacts (not available on Azure SQL Database) ---------- */
IF @IsAzureSqlDb = 0
BEGIN
    BEGIN TRY
        INSERT INTO #Artifacts (DatabaseName, ArtifactScope, ArtifactType, ArtifactName, IdentityValue, UsesManagedIdentity, InScopeForMI)
        SELECT N'master', N'Server', N'Server Credential',
               CONVERT(NVARCHAR(256), c.name),
               CONVERT(NVARCHAR(512), ISNULL(c.credential_identity, N'(none)')),
               CASE WHEN c.credential_identity LIKE N'%Managed Identity%'
                      OR c.credential_identity LIKE N'%Managed Service Identity%'
                      OR c.credential_identity LIKE N'%$' THEN 1 ELSE 0 END,
               1
        FROM sys.credentials AS c;
    END TRY
    BEGIN CATCH
    END CATCH

    /* Linked servers are context only: Managed Identity is not a supported linked server auth mode. */
    BEGIN TRY
        INSERT INTO #Artifacts (DatabaseName, ArtifactScope, ArtifactType, ArtifactName, IdentityValue, UsesManagedIdentity, InScopeForMI)
        SELECT N'master', N'Server', N'Linked Server',
               CONVERT(NVARCHAR(256), s.name),
               CONVERT(NVARCHAR(512), ISNULL(MAX(l.remote_name), N'(pass-through / self credential)')),
               0,
               0
        FROM sys.servers AS s
        LEFT JOIN sys.linked_logins AS l ON l.server_id = s.server_id
        WHERE s.is_linked = 1
        GROUP BY s.name;
    END TRY
    BEGIN CATCH
    END CATCH
END

/* ---------- 4. Evaluate ---------- */
DECLARE @InScope INT = (SELECT COUNT(*) FROM #Artifacts WHERE InScopeForMI = 1);
DECLARE @MiCount INT = (SELECT COUNT(*) FROM #Artifacts WHERE InScopeForMI = 1 AND UsesManagedIdentity = 1);
DECLARE @NonMi   INT = (SELECT COUNT(*) FROM #Artifacts WHERE InScopeForMI = 1 AND UsesManagedIdentity = 0);
DECLARE @Entra   INT = (SELECT COUNT(*) FROM #Artifacts WHERE ArtifactType = N'Entra ID Database Principal');
DECLARE @Linked  INT = (SELECT COUNT(*) FROM #Artifacts WHERE ArtifactType = N'Linked Server');
DECLARE @DbCount INT = (SELECT COUNT(*) FROM #Dbs);

DECLARE @DbList NVARCHAR(MAX) =
    STUFF((SELECT N', ' + d.DatabaseName
           FROM #Dbs AS d
           ORDER BY d.DatabaseName
           FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'');
SET @DbList = LEFT(ISNULL(NULLIF(@DbList, N''), N'(none)'), 3000);

DECLARE @NonMiList NVARCHAR(MAX) =
    STUFF((SELECT TOP (10) N'; ' + a.DatabaseName + N'.' + a.ArtifactType + N' [' + a.ArtifactName + N'] identity=' + ISNULL(a.IdentityValue, N'(none)')
           FROM #Artifacts AS a
           WHERE a.InScopeForMI = 1 AND a.UsesManagedIdentity = 0
           ORDER BY a.DatabaseName, a.ArtifactType, a.ArtifactName
           FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'');
SET @NonMiList = ISNULL(@NonMiList, N'none');

DECLARE @Result  NVARCHAR(20);
DECLARE @Score   INT;
DECLARE @Finding NVARCHAR(MAX);

IF @InScope = 0
BEGIN
    SET @Score = 2;
    SET @Finding = CONCAT(
        N'No credential-based service-to-service authentication artifacts were found across ', @DbCount,
        N' database(s): server credentials, database scoped credentials and credential-bound external data sources all returned 0. ',
        N'Context: ', @Linked, N' linked server(s) and ', @Entra, N' Entra ID database principal(s) present. ',
        CASE WHEN @SupportsDbScoped = 0
             THEN N'This build predates database scoped credentials, so only server credentials could be inspected. '
             ELSE N'' END,
        N'No stored secret is used for outbound authentication, but Managed Identity usage must be confirmed manually for any integration configured outside the database engine.');
END
ELSE IF @NonMi = 0
BEGIN
    SET @Score = 3;
    SET @Finding = CONCAT(
        N'All ', @InScope, N' service-to-service authentication artifact(s) across ', @DbCount,
        N' database(s) authenticate with a Managed Identity (or gMSA equivalent); 0 use a stored secret, password or shared access signature. ',
        N'Context: ', @Linked, N' linked server(s) and ', @Entra, N' Entra ID database principal(s) present; Managed Identity is not a supported linked server auth mode, so linked servers are excluded from scoring.');
END
ELSE IF @MiCount > 0
BEGIN
    SET @Score = 1;
    SET @Finding = CONCAT(
        N'Mixed authentication: ', @MiCount, N' of ', @InScope,
        N' service-to-service authentication artifact(s) across ', @DbCount, N' database(s) use a Managed Identity, but ',
        @NonMi, N' still authenticate with a stored secret, password or shared access signature. Secret-based artifacts: ',
        LEFT(@NonMiList, 1200), N'.');
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = CONCAT(
        N'None of the ', @InScope, N' service-to-service authentication artifact(s) across ', @DbCount,
        N' database(s) use a Managed Identity; every one authenticates with a stored secret, password or shared access signature. Artifacts: ',
        LEFT(@NonMiList, 1200), N'.');
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;
IF OBJECT_ID('tempdb..#Artifacts') IS NOT NULL DROP TABLE #Artifacts;

SELECT
    @Result  AS Result,
    @Score   AS Score,
    @DbList  AS DatabaseQueried,
    @Finding AS Finding;