/*==============================================================================
  Checklist Item : 7.4.2 - Login/permission changes captured and reviewable
  Area           : Compliance & Regulatory
  Scope          : SERVER
  Type           : Read-only (catalog views / DMVs only; temp tables only)
  Output         : Result, Score, DatabaseQueried, Finding
==============================================================================*/
SET NOCOUNT ON;

DECLARE @IsAzureSqlDb    bit = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @CollectionError nvarchar(2000) = NULL;

IF OBJECT_ID('tempdb..#AuditCoverage') IS NOT NULL DROP TABLE #AuditCoverage;
CREATE TABLE #AuditCoverage
(
    AuditName         sysname        NULL,
    AuditIsEnabled    bit            NULL,
    AuditStatus       nvarchar(60)   NULL,
    Destination       nvarchar(60)   NULL,
    SpecificationName sysname        NULL,
    SpecIsEnabled     bit            NULL,
    SpecScope         nvarchar(20)   NULL,
    DatabaseName      sysname        NULL,
    ActionGroup       nvarchar(128)  NULL
);

IF OBJECT_ID('tempdb..#RequiredGroups') IS NOT NULL DROP TABLE #RequiredGroups;
CREATE TABLE #RequiredGroups (ActionGroup nvarchar(128) NOT NULL PRIMARY KEY);

/*--------------------------------------------------------------------------
  1. Required action groups (Azure SQL DB cannot audit SERVER_* groups)
--------------------------------------------------------------------------*/
INSERT INTO #RequiredGroups (ActionGroup)
VALUES (N'DATABASE_PRINCIPAL_CHANGE_GROUP'),
       (N'DATABASE_ROLE_MEMBER_CHANGE_GROUP'),
       (N'DATABASE_PERMISSION_CHANGE_GROUP');

IF @IsAzureSqlDb = 0
    INSERT INTO #RequiredGroups (ActionGroup)
    VALUES (N'SERVER_PRINCIPAL_CHANGE_GROUP'),
           (N'SERVER_ROLE_MEMBER_CHANGE_GROUP'),
           (N'SERVER_PERMISSION_CHANGE_GROUP');

/*--------------------------------------------------------------------------
  2. Collect audit configuration
--------------------------------------------------------------------------*/
IF @IsAzureSqlDb = 0
BEGIN
    DECLARE @sql nvarchar(max);

    -- Server audits + server audit specifications (deferred resolution: not present on Azure SQL DB)
    BEGIN TRY
        SET @sql = N'
            INSERT INTO #AuditCoverage
                (AuditName, AuditIsEnabled, AuditStatus, Destination,
                 SpecificationName, SpecIsEnabled, SpecScope, DatabaseName, ActionGroup)
            SELECT a.name,
                   a.is_state_enabled,
                   ISNULL(st.status_desc, N''UNKNOWN''),
                   a.type_desc,
                   s.name,
                   s.is_state_enabled,
                   N''SERVER'',
                   NULL,
                   d.audit_action_name
            FROM sys.server_audits AS a
            LEFT JOIN sys.dm_server_audit_status AS st
                   ON st.audit_id = a.audit_id
            LEFT JOIN sys.server_audit_specifications AS s
                   ON s.audit_guid = a.audit_guid
            LEFT JOIN sys.server_audit_specification_details AS d
                   ON d.server_specification_id = s.server_specification_id;';
        EXEC sys.sp_executesql @sql;
    END TRY
    BEGIN CATCH
        SET @CollectionError = N'Server audit metadata could not be read: ' + ERROR_MESSAGE();
    END CATCH

    -- Database audit specifications in every accessible online database
    IF @CollectionError IS NULL
    BEGIN
        DECLARE @db  sysname;
        DECLARE @cmd nvarchar(max);

        DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT d.name
            FROM sys.databases AS d
            WHERE d.state_desc = 'ONLINE'
              AND d.source_database_id IS NULL
              AND HAS_DBACCESS(d.name) = 1;

        OPEN db_cur;
        FETCH NEXT FROM db_cur INTO @db;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @cmd = N'
                INSERT INTO #AuditCoverage
                    (AuditName, AuditIsEnabled, AuditStatus, Destination,
                     SpecificationName, SpecIsEnabled, SpecScope, DatabaseName, ActionGroup)
                SELECT a.name,
                       a.is_state_enabled,
                       ISNULL(st.status_desc, N''UNKNOWN''),
                       a.type_desc,
                       s.name,
                       s.is_state_enabled,
                       N''DATABASE'',
                       @dbName,
                       d.audit_action_name
                FROM ' + QUOTENAME(@db) + N'.sys.database_audit_specifications AS s
                LEFT JOIN sys.server_audits AS a
                       ON a.audit_guid = s.audit_guid
                LEFT JOIN sys.dm_server_audit_status AS st
                       ON st.audit_id = a.audit_id
                LEFT JOIN ' + QUOTENAME(@db) + N'.sys.database_audit_specification_details AS d
                       ON d.database_specification_id = s.database_specification_id;';

            BEGIN TRY
                EXEC sys.sp_executesql @cmd, N'@dbName sysname', @dbName = @db;
            END TRY
            BEGIN CATCH
                /* database unreadable for this principal - skipped, reported via coverage gaps */
            END CATCH

            FETCH NEXT FROM db_cur INTO @db;
        END

        CLOSE db_cur;
        DEALLOCATE db_cur;
    END
END
ELSE
BEGIN
    -- Azure SQL Database: auditing is surfaced through the current database only
    BEGIN TRY
        INSERT INTO #AuditCoverage
            (AuditName, AuditIsEnabled, AuditStatus, Destination,
             SpecificationName, SpecIsEnabled, SpecScope, DatabaseName, ActionGroup)
        SELECT N'(Azure managed audit)',
               1,
               N'AZURE',
               N'AZURE',
               s.name,
               s.is_state_enabled,
               N'DATABASE',
               DB_NAME(),
               d.audit_action_name
        FROM sys.database_audit_specifications AS s
        LEFT JOIN sys.database_audit_specification_details AS d
               ON d.database_specification_id = s.database_specification_id;
    END TRY
    BEGIN CATCH
        SET @CollectionError = N'Database audit metadata could not be read: ' + ERROR_MESSAGE();
    END CATCH
END

/*--------------------------------------------------------------------------
  3. Default trace (limited, short-retention fallback capture)
--------------------------------------------------------------------------*/
DECLARE @DefaultTraceEnabled int = 0;

IF @IsAzureSqlDb = 0
BEGIN
    SELECT @DefaultTraceEnabled = ISNULL(CONVERT(int, c.value_in_use), 0)
    FROM sys.configurations AS c
    WHERE c.name = 'default trace enabled';
END

/*--------------------------------------------------------------------------
  4. Determine active coverage
--------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#ActiveGroups') IS NOT NULL DROP TABLE #ActiveGroups;
CREATE TABLE #ActiveGroups (ActionGroup nvarchar(128) NOT NULL PRIMARY KEY);

INSERT INTO #ActiveGroups (ActionGroup)
SELECT DISTINCT c.ActionGroup
FROM #AuditCoverage AS c
WHERE c.ActionGroup IS NOT NULL
  AND ISNULL(c.SpecIsEnabled, 0) = 1
  AND ISNULL(c.AuditIsEnabled, 0) = 1
  AND ISNULL(c.AuditStatus, N'UNKNOWN') <> N'STOPPED'
  AND ISNULL(c.Destination, N'') IN (N'FILE', N'APPLICATION LOG', N'SECURITY LOG', N'AZURE');

DECLARE @RequiredCount int = (SELECT COUNT(*) FROM #RequiredGroups);
DECLARE @CoveredCount  int =
(
    SELECT COUNT(*)
    FROM #RequiredGroups AS r
    WHERE EXISTS (SELECT 1 FROM #ActiveGroups AS a WHERE a.ActionGroup = r.ActionGroup)
);

DECLARE @MissingGroups nvarchar(max) =
    STUFF((SELECT N', ' + r.ActionGroup
           FROM #RequiredGroups AS r
           WHERE NOT EXISTS (SELECT 1 FROM #ActiveGroups AS a WHERE a.ActionGroup = r.ActionGroup)
           ORDER BY r.ActionGroup
           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

DECLARE @AuditSummary nvarchar(max) =
    STUFF((SELECT DISTINCT N'; ' + ISNULL(c.AuditName, N'(no audit)')
                  + N' [dest=' + ISNULL(c.Destination, N'n/a')
                  + N', auditEnabled=' + CASE WHEN ISNULL(c.AuditIsEnabled, 0) = 1 THEN N'Y' ELSE N'N' END
                  + N', status=' + ISNULL(c.AuditStatus, N'UNKNOWN')
                  + N', spec=' + ISNULL(c.SpecificationName, N'(none)')
                  + N' (' + ISNULL(c.SpecScope, N'?')
                  + CASE WHEN c.DatabaseName IS NULL THEN N'' ELSE N':' + c.DatabaseName END + N')'
                  + N', specEnabled=' + CASE WHEN ISNULL(c.SpecIsEnabled, 0) = 1 THEN N'Y' ELSE N'N' END + N']'
           FROM #AuditCoverage AS c
           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

/*--------------------------------------------------------------------------
  5. Score
--------------------------------------------------------------------------*/
DECLARE @Score           int;
DECLARE @Result          nvarchar(20);
DECLARE @Finding         nvarchar(max);
DECLARE @DatabaseQueried nvarchar(256) =
    CASE WHEN @IsAzureSqlDb = 1 THEN DB_NAME() ELSE N'master' END;

IF @CollectionError IS NOT NULL
BEGIN
    SET @Score   = 1;
    SET @Finding = N'Unable to verify login/permission change auditing. ' + @CollectionError
                 + N' Re-run with a principal holding VIEW ANY DEFINITION and VIEW SERVER STATE (or CONTROL SERVER) and confirm manually.';
END
ELSE IF @RequiredCount > 0 AND @CoveredCount = @RequiredCount
BEGIN
    SET @Score   = 3;
    SET @Finding = N'Login and permission change events are captured by an active SQL Server Audit writing to a persistent, reviewable destination. All '
                 + CONVERT(nvarchar(10), @RequiredCount) + N' required action groups are covered ('
                 + STUFF((SELECT N', ' + r.ActionGroup FROM #RequiredGroups AS r ORDER BY r.ActionGroup
                          FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'')
                 + N'). Audit configuration: ' + LEFT(ISNULL(@AuditSummary, N'n/a'), 2000) + N'.';
END
ELSE IF @CoveredCount > 0
BEGIN
    SET @Score   = 2;
    SET @Finding = N'Login/permission change auditing is only partially configured: '
                 + CONVERT(nvarchar(10), @CoveredCount) + N' of ' + CONVERT(nvarchar(10), @RequiredCount)
                 + N' required action groups are covered by an enabled audit specification on an enabled audit. Missing group(s): '
                 + ISNULL(@MissingGroups, N'(none)') + N'. Audit configuration: '
                 + LEFT(ISNULL(@AuditSummary, N'n/a'), 2000) + N'.';
END
ELSE IF @DefaultTraceEnabled = 1
BEGIN
    SET @Score   = 2;
    SET @Finding = N'No enabled SQL Server Audit captures login or permission changes. The default trace is enabled and records some Audit Add Login, Audit Login Change Password, Audit Add DB User and Audit Add Role Member events, but it rolls over across five 20 MB files, so history is short-lived and not reliably reviewable. Missing group(s): '
                 + ISNULL(@MissingGroups, N'(all required groups)') + N'. Audit configuration: '
                 + LEFT(ISNULL(@AuditSummary, N'no SQL Server Audit objects found'), 2000) + N'.';
END
ELSE
BEGIN
    SET @Score   = 1;
    SET @Finding = N'No mechanism captures login or permission changes: no enabled SQL Server Audit specification covers any required action group'
                 + CASE WHEN @IsAzureSqlDb = 1 THEN N'' ELSE N' and the default trace is disabled' END
                 + N'. Missing group(s): ' + ISNULL(@MissingGroups, N'(all required groups)')
                 + N'. Audit configuration: ' + LEFT(ISNULL(@AuditSummary, N'no SQL Server Audit objects found'), 2000) + N'.';
END

SET @Result = CASE WHEN @Score = 3 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;

IF OBJECT_ID('tempdb..#ActiveGroups')   IS NOT NULL DROP TABLE #ActiveGroups;
IF OBJECT_ID('tempdb..#RequiredGroups') IS NOT NULL DROP TABLE #RequiredGroups;
IF OBJECT_ID('tempdb..#AuditCoverage')  IS NOT NULL DROP TABLE #AuditCoverage;