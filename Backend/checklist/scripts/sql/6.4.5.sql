SET NOCOUNT ON;

/* 6.4.5 - Linked servers / external data sources use least-privilege, non-personal credentials
   READ-ONLY: catalog views only. Temp tables are used to stage findings. */

DECLARE @Result NVARCHAR(50);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(256) = N'master';
DECLARE @Finding NVARCHAR(MAX);

IF OBJECT_ID('tempdb..#LinkedLogins') IS NOT NULL DROP TABLE #LinkedLogins;
IF OBJECT_ID('tempdb..#ExternalDS') IS NOT NULL DROP TABLE #ExternalDS;

CREATE TABLE #LinkedLogins
(
    ServerName          SYSNAME        NOT NULL,
    ProviderName        NVARCHAR(128)  NULL,
    DataSource          NVARCHAR(4000) NULL,
    LocalPrincipal      NVARCHAR(256)  NULL,
    UsesSelfCredential  BIT            NULL,
    RemoteName          NVARCHAR(256)  NULL,
    IsPrivileged        BIT            NOT NULL DEFAULT (0),
    IsWildcardShared    BIT            NOT NULL DEFAULT (0)
);

CREATE TABLE #ExternalDS
(
    DatabaseName        SYSNAME        NOT NULL,
    DataSourceName      SYSNAME        NOT NULL,
    Location            NVARCHAR(4000) NULL,
    CredentialName      NVARCHAR(256)  NULL,
    CredentialIdentity  NVARCHAR(4000) NULL,
    IsPrivileged        BIT            NOT NULL DEFAULT (0),
    IsUnattributed      BIT            NOT NULL DEFAULT (0)
);

BEGIN TRY
    /* ---------- Linked server login mappings (server scope) ---------- */
    INSERT INTO #LinkedLogins (ServerName, ProviderName, DataSource, LocalPrincipal, UsesSelfCredential, RemoteName)
    SELECT
        s.name,
        s.provider,
        s.data_source,
        CASE WHEN ll.local_principal_id = 0 THEN N'(all logins)' ELSE ISNULL(sp.name, N'principal_id ' + CONVERT(NVARCHAR(20), ll.local_principal_id)) END,
        ll.uses_self_credential,
        ll.remote_name
    FROM sys.servers AS s
    INNER JOIN sys.linked_logins AS ll
        ON ll.server_id = s.server_id
    LEFT JOIN sys.server_principals AS sp
        ON sp.principal_id = ll.local_principal_id
    WHERE s.is_linked = 1;

    UPDATE #LinkedLogins
    SET IsPrivileged = 1
    WHERE UsesSelfCredential = 0
      AND RemoteName IS NOT NULL
      AND (
            LOWER(LTRIM(RTRIM(RemoteName))) IN (N'sa', N'root', N'dbo', N'administrator', N'admin')
            OR LOWER(RemoteName) LIKE N'%administrator'
            OR LOWER(RemoteName) LIKE N'admin%'
            OR LOWER(RemoteName) LIKE N'%sysadmin%'
          );

    UPDATE #LinkedLogins
    SET IsWildcardShared = 1
    WHERE LocalPrincipal = N'(all logins)'
      AND UsesSelfCredential = 0
      AND RemoteName IS NOT NULL
      AND IsPrivileged = 0;

    /* ---------- External data sources (database scope) ---------- */
    IF CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5
    BEGIN
        /* Azure SQL Database: cannot switch database context */
        SET @DatabaseQueried = DB_NAME();

        IF OBJECT_ID('sys.external_data_sources', 'V') IS NOT NULL
        BEGIN
            INSERT INTO #ExternalDS (DatabaseName, DataSourceName, Location, CredentialName, CredentialIdentity)
            SELECT DB_NAME(), eds.name, eds.location, dsc.name, dsc.credential_identity
            FROM sys.external_data_sources AS eds
            LEFT JOIN sys.database_scoped_credentials AS dsc
                ON dsc.credential_id = eds.credential_id;
        END
    END
    ELSE
    BEGIN
        DECLARE @db SYSNAME;
        DECLARE @sql NVARCHAR(MAX);

        DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT d.name
            FROM sys.databases AS d
            WHERE d.state = 0
              AND d.source_database_id IS NULL
              AND HAS_DBACCESS(d.name) = 1
            ORDER BY d.name;

        OPEN db_cur;
        FETCH NEXT FROM db_cur INTO @db;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @sql = N'USE ' + QUOTENAME(@db) + N';
IF OBJECT_ID(''sys.external_data_sources'', ''V'') IS NOT NULL
    SELECT DB_NAME(), eds.name, eds.location, dsc.name, dsc.credential_identity
    FROM sys.external_data_sources AS eds
    LEFT JOIN sys.database_scoped_credentials AS dsc
        ON dsc.credential_id = eds.credential_id;';

                INSERT INTO #ExternalDS (DatabaseName, DataSourceName, Location, CredentialName, CredentialIdentity)
                EXEC sys.sp_executesql @sql;
            END TRY
            BEGIN CATCH
                /* database inaccessible or feature unsupported - skip */
            END CATCH

            FETCH NEXT FROM db_cur INTO @db;
        END

        CLOSE db_cur;
        DEALLOCATE db_cur;

        SET @DatabaseQueried = N'master (all accessible databases)';
    END

    UPDATE #ExternalDS
    SET IsPrivileged = 1
    WHERE CredentialIdentity IS NOT NULL
      AND (
            LOWER(LTRIM(RTRIM(CredentialIdentity))) IN (N'sa', N'root', N'dbo', N'administrator', N'admin')
            OR LOWER(CredentialIdentity) LIKE N'admin%'
            OR LOWER(CredentialIdentity) LIKE N'%administrator'
            OR LOWER(CredentialIdentity) LIKE N'%sysadmin%'
          );

    UPDATE #ExternalDS
    SET IsUnattributed = 1
    WHERE CredentialName IS NULL
      AND IsPrivileged = 0;

    /* ---------- Evaluate ---------- */
    DECLARE @LinkedServerCount    INT = (SELECT COUNT(DISTINCT ServerName) FROM #LinkedLogins);
    DECLARE @MappingCount         INT = (SELECT COUNT(*) FROM #LinkedLogins);
    DECLARE @PrivLoginCount       INT = (SELECT COUNT(*) FROM #LinkedLogins WHERE IsPrivileged = 1);
    DECLARE @WildcardCount        INT = (SELECT COUNT(*) FROM #LinkedLogins WHERE IsWildcardShared = 1);
    DECLARE @EdsCount             INT = (SELECT COUNT(*) FROM #ExternalDS);
    DECLARE @PrivEdsCount         INT = (SELECT COUNT(*) FROM #ExternalDS WHERE IsPrivileged = 1);
    DECLARE @UnattributedEdsCount INT = (SELECT COUNT(*) FROM #ExternalDS WHERE IsUnattributed = 1);

    DECLARE @PrivExamples NVARCHAR(MAX) =
        STUFF((
            SELECT TOP (5) N'; ' + x.Detail
            FROM (
                SELECT ServerName + N' -> remote login ''' + ISNULL(RemoteName, N'(none)') + N''' for ' + ISNULL(LocalPrincipal, N'(unknown)') AS Detail
                FROM #LinkedLogins WHERE IsPrivileged = 1
                UNION ALL
                SELECT DatabaseName + N'.' + DataSourceName + N' -> credential identity ''' + ISNULL(CredentialIdentity, N'(none)') + N''''
                FROM #ExternalDS WHERE IsPrivileged = 1
            ) AS x
            ORDER BY x.Detail
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

    DECLARE @WeakExamples NVARCHAR(MAX) =
        STUFF((
            SELECT TOP (5) N'; ' + y.Detail
            FROM (
                SELECT ServerName + N' -> all logins share stored remote login ''' + ISNULL(RemoteName, N'(none)') + N'''' AS Detail
                FROM #LinkedLogins WHERE IsWildcardShared = 1
                UNION ALL
                SELECT DatabaseName + N'.' + DataSourceName + N' -> no database scoped credential attributed'
                FROM #ExternalDS WHERE IsUnattributed = 1
            ) AS y
            ORDER BY y.Detail
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

    IF @PrivLoginCount > 0 OR @PrivEdsCount > 0
    BEGIN
        SET @Score = 1;
        SET @Finding = N'Privileged/shared administrative credentials are used for external connectivity: '
            + CONVERT(NVARCHAR(20), @PrivLoginCount) + N' of ' + CONVERT(NVARCHAR(20), @MappingCount)
            + N' linked-login mapping(s) across ' + CONVERT(NVARCHAR(20), @LinkedServerCount) + N' linked server(s) and '
            + CONVERT(NVARCHAR(20), @PrivEdsCount) + N' of ' + CONVERT(NVARCHAR(20), @EdsCount)
            + N' external data source(s). Examples: ' + ISNULL(@PrivExamples, N'(none)') + N'.';
    END
    ELSE IF @WildcardCount > 0 OR @UnattributedEdsCount > 0
    BEGIN
        SET @Score = 2;
        SET @Finding = N'No administrative remote logins were found, but least-privilege attribution is incomplete: '
            + CONVERT(NVARCHAR(20), @WildcardCount) + N' wildcard (all logins) mapping(s) use a shared stored credential and '
            + CONVERT(NVARCHAR(20), @UnattributedEdsCount) + N' external data source(s) have no database scoped credential. '
            + N'Totals: ' + CONVERT(NVARCHAR(20), @LinkedServerCount) + N' linked server(s), '
            + CONVERT(NVARCHAR(20), @MappingCount) + N' mapping(s), ' + CONVERT(NVARCHAR(20), @EdsCount)
            + N' external data source(s). Examples: ' + ISNULL(@WeakExamples, N'(none)') + N'.';
    END
    ELSE IF @LinkedServerCount = 0 AND @EdsCount = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = N'No linked servers and no external data sources are defined on this instance, so no external credential exposure exists.';
    END
    ELSE
    BEGIN
        SET @Score = 3;
        SET @Finding = N'All external connectivity uses least-privilege credentials: '
            + CONVERT(NVARCHAR(20), @LinkedServerCount) + N' linked server(s) with '
            + CONVERT(NVARCHAR(20), @MappingCount) + N' login mapping(s) and '
            + CONVERT(NVARCHAR(20), @EdsCount) + N' external data source(s); no sa/admin/root remote logins or credential identities and no shared wildcard stored credentials were found.';
    END
END TRY
BEGIN CATCH
    SET @Score = 1;
    SET @Finding = N'Unable to evaluate linked server / external data source credentials: ' + ERROR_MESSAGE();
END CATCH

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#LinkedLogins') IS NOT NULL DROP TABLE #LinkedLogins;
IF OBJECT_ID('tempdb..#ExternalDS') IS NOT NULL DROP TABLE #ExternalDS;