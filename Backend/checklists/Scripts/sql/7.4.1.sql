SET NOCOUNT ON;

/* Checklist 7.4.1 - SQL Audit (server/database) enabled for sensitive operations. Read-only. */

DECLARE @EngineEdition int = CAST(SERVERPROPERTY('EngineEdition') AS int);
DECLARE @IsAzureSqlDb bit = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;
DECLARE @DatabaseQueried nvarchar(256) =
    CASE WHEN @EngineEdition = 5
         THEN DB_NAME()
         ELSE ISNULL(CAST(SERVERPROPERTY('ServerName') AS nvarchar(256)), CAST(@@SERVERNAME AS nvarchar(256)))
    END;

DECLARE @Result nvarchar(20);
DECLARE @Score int;
DECLARE @Finding nvarchar(4000);

IF OBJECT_ID('tempdb..#RequiredGroups') IS NOT NULL DROP TABLE #RequiredGroups;
IF OBJECT_ID('tempdb..#CoveredGroups') IS NOT NULL DROP TABLE #CoveredGroups;
IF OBJECT_ID('tempdb..#Audits') IS NOT NULL DROP TABLE #Audits;
IF OBJECT_ID('tempdb..#Specs') IS NOT NULL DROP TABLE #Specs;

CREATE TABLE #RequiredGroups (ActionGroup nvarchar(128) NOT NULL PRIMARY KEY);
CREATE TABLE #CoveredGroups (ActionGroup nvarchar(128) NOT NULL, SourceScope nvarchar(20) NOT NULL, SourceName nvarchar(600) NOT NULL);
CREATE TABLE #Audits (AuditName sysname NOT NULL, IsEnabled bit NOT NULL, AuditDestination nvarchar(128) NULL);
CREATE TABLE #Specs (SpecName sysname NOT NULL, SpecScope nvarchar(20) NOT NULL, DatabaseName nvarchar(256) NULL, IsEnabled bit NOT NULL, AuditName sysname NULL, AuditEnabled bit NULL);

INSERT INTO #RequiredGroups (ActionGroup)
VALUES
    (N'SUCCESSFUL_LOGIN_GROUP'),
    (N'FAILED_LOGIN_GROUP'),
    (N'SERVER_ROLE_MEMBER_CHANGE_GROUP'),
    (N'SERVER_PERMISSION_CHANGE_GROUP'),
    (N'AUDIT_CHANGE_GROUP'),
    (N'DATABASE_ROLE_MEMBER_CHANGE_GROUP'),
    (N'DATABASE_PERMISSION_CHANGE_GROUP'),
    (N'SCHEMA_OBJECT_CHANGE_GROUP');

IF @IsAzureSqlDb = 0
BEGIN
    /* Server-level audit catalog views are absent on Azure SQL Database, so they are reached through dynamic SQL. */
    DECLARE @ServerSql nvarchar(max) = N'
        INSERT INTO #Audits (AuditName, IsEnabled, AuditDestination)
        SELECT sa.name, sa.is_state_enabled, sa.type_desc
        FROM sys.server_audits AS sa;

        INSERT INTO #Specs (SpecName, SpecScope, DatabaseName, IsEnabled, AuditName, AuditEnabled)
        SELECT sas.name, N''SERVER'', NULL, sas.is_state_enabled, sa.name, sa.is_state_enabled
        FROM sys.server_audit_specifications AS sas
        LEFT JOIN sys.server_audits AS sa ON sa.audit_guid = sas.audit_guid;

        INSERT INTO #CoveredGroups (ActionGroup, SourceScope, SourceName)
        SELECT d.audit_action_name, N''SERVER'', sas.name
        FROM sys.server_audit_specification_details AS d
        INNER JOIN sys.server_audit_specifications AS sas
            ON sas.server_specification_id = d.server_specification_id
        INNER JOIN sys.server_audits AS sa
            ON sa.audit_guid = sas.audit_guid
        WHERE sas.is_state_enabled = 1
          AND sa.is_state_enabled = 1;';

    BEGIN TRY
        EXEC sys.sp_executesql @ServerSql;
    END TRY
    BEGIN CATCH
        SET @Finding = N'Server-level audit metadata could not be read (' + ISNULL(ERROR_MESSAGE(), N'unknown error') + N'). ';
    END CATCH

    DECLARE @db sysname;
    DECLARE @DbSql nvarchar(max);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.state = 0
          AND d.source_database_id IS NULL
          AND d.database_id <> 2
          AND HAS_DBACCESS(d.name) = 1;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @DbSql = N'
            INSERT INTO #Specs (SpecName, SpecScope, DatabaseName, IsEnabled, AuditName, AuditEnabled)
            SELECT das.name, N''DATABASE'', @dbname, das.is_state_enabled, sa.name, sa.is_state_enabled
            FROM ' + QUOTENAME(@db) + N'.sys.database_audit_specifications AS das
            LEFT JOIN sys.server_audits AS sa ON sa.audit_guid = das.audit_guid;

            INSERT INTO #CoveredGroups (ActionGroup, SourceScope, SourceName)
            SELECT d.audit_action_name, N''DATABASE'', @dbname + N''.'' + das.name
            FROM ' + QUOTENAME(@db) + N'.sys.database_audit_specification_details AS d
            INNER JOIN ' + QUOTENAME(@db) + N'.sys.database_audit_specifications AS das
                ON das.database_specification_id = d.database_specification_id
            INNER JOIN sys.server_audits AS sa
                ON sa.audit_guid = das.audit_guid
            WHERE das.is_state_enabled = 1
              AND sa.is_state_enabled = 1;';

        BEGIN TRY
            EXEC sys.sp_executesql @DbSql, N'@dbname nvarchar(256)', @dbname = @db;
        END TRY
        BEGIN CATCH
            /* Database is inaccessible to this login; it is skipped rather than failing the check. */
            SET @Finding = ISNULL(@Finding, N'') + N'Skipped database [' + @db + N'] (' + ISNULL(ERROR_MESSAGE(), N'access error') + N'). ';
        END CATCH

        FETCH NEXT FROM db_cursor INTO @db;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END
ELSE
BEGIN
    /* Azure SQL Database: only database-scoped audit specifications are visible through T-SQL. */
    BEGIN TRY
        INSERT INTO #Specs (SpecName, SpecScope, DatabaseName, IsEnabled, AuditName, AuditEnabled)
        SELECT das.name, N'DATABASE', DB_NAME(), das.is_state_enabled, NULL, NULL
        FROM sys.database_audit_specifications AS das;

        INSERT INTO #CoveredGroups (ActionGroup, SourceScope, SourceName)
        SELECT d.audit_action_name, N'DATABASE', DB_NAME() + N'.' + das.name
        FROM sys.database_audit_specification_details AS d
        INNER JOIN sys.database_audit_specifications AS das
            ON das.database_specification_id = d.database_specification_id
        WHERE das.is_state_enabled = 1;
    END TRY
    BEGIN CATCH
        SET @Finding = N'Database audit metadata could not be read (' + ISNULL(ERROR_MESSAGE(), N'unknown error') + N'). ';
    END CATCH
END

DECLARE @TotalAudits int = (SELECT COUNT(*) FROM #Audits);
DECLARE @EnabledAudits int = (SELECT COUNT(*) FROM #Audits WHERE IsEnabled = 1);
DECLARE @TotalSpecs int = (SELECT COUNT(*) FROM #Specs);
DECLARE @EffectiveSpecs int =
    (SELECT COUNT(*) FROM #Specs
     WHERE IsEnabled = 1
       AND (@IsAzureSqlDb = 1 OR ISNULL(AuditEnabled, 0) = 1));

DECLARE @RequiredCount int = (SELECT COUNT(*) FROM #RequiredGroups);
DECLARE @CoveredCount int =
    (SELECT COUNT(*) FROM #RequiredGroups AS r
     WHERE EXISTS (SELECT 1 FROM #CoveredGroups AS c WHERE c.ActionGroup = r.ActionGroup));

DECLARE @MissingGroups nvarchar(2000) =
    STUFF((SELECT N', ' + r.ActionGroup
           FROM #RequiredGroups AS r
           WHERE NOT EXISTS (SELECT 1 FROM #CoveredGroups AS c WHERE c.ActionGroup = r.ActionGroup)
           ORDER BY r.ActionGroup
           FOR XML PATH(''), TYPE).value('.', 'nvarchar(2000)'), 1, 2, N'');

DECLARE @EnabledAuditNames nvarchar(2000) =
    STUFF((SELECT N', ' + a.AuditName
           FROM #Audits AS a
           WHERE a.IsEnabled = 1
           ORDER BY a.AuditName
           FOR XML PATH(''), TYPE).value('.', 'nvarchar(2000)'), 1, 2, N'');

DECLARE @EffectiveSpecNames nvarchar(2000) =
    STUFF((SELECT N', ' + s.SpecScope + N':' + ISNULL(s.DatabaseName + N'.', N'') + s.SpecName
           FROM #Specs AS s
           WHERE s.IsEnabled = 1
             AND (@IsAzureSqlDb = 1 OR ISNULL(s.AuditEnabled, 0) = 1)
           ORDER BY s.SpecScope, s.SpecName
           FOR XML PATH(''), TYPE).value('.', 'nvarchar(2000)'), 1, 2, N'');

SET @Finding = ISNULL(@Finding, N'');

IF @IsAzureSqlDb = 1
BEGIN
    IF @TotalSpecs = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = @Finding + N'Azure SQL Database [' + @DatabaseQueried + N']: no database audit specification exists, so no sensitive operations are audited at the database level. Server-level Azure auditing policy is not visible through T-SQL and must be confirmed separately.';
    END
    ELSE IF @EffectiveSpecs = 0
    BEGIN
        SET @Score = 1;
        SET @Finding = @Finding + N'Azure SQL Database [' + @DatabaseQueried + N']: ' + CAST(@TotalSpecs AS nvarchar(10)) + N' database audit specification(s) exist but none is enabled, so no audit records are being collected.';
    END
    ELSE IF @CoveredCount < @RequiredCount
    BEGIN
        SET @Score = 2;
        SET @Finding = @Finding + N'Azure SQL Database [' + @DatabaseQueried + N']: enabled audit specification(s) (' + ISNULL(@EffectiveSpecNames, N'n/a') + N') cover ' + CAST(@CoveredCount AS nvarchar(10)) + N' of ' + CAST(@RequiredCount AS nvarchar(10)) + N' required sensitive action groups. Missing: ' + ISNULL(@MissingGroups, N'n/a') + N'.';
    END
    ELSE
    BEGIN
        SET @Score = 3;
        SET @Finding = @Finding + N'Azure SQL Database [' + @DatabaseQueried + N']: enabled audit specification(s) (' + ISNULL(@EffectiveSpecNames, N'n/a') + N') cover all ' + CAST(@RequiredCount AS nvarchar(10)) + N' required sensitive action groups.';
    END
END
ELSE
BEGIN
    IF @TotalAudits = 0 AND @TotalSpecs = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = @Finding + N'Instance [' + @DatabaseQueried + N']: no SQL Server Audit object and no audit specification exist. Sensitive operations such as logins, permission changes and schema changes are not being audited.';
    END
    ELSE IF @EnabledAudits = 0
    BEGIN
        SET @Score = 1;
        SET @Finding = @Finding + N'Instance [' + @DatabaseQueried + N']: ' + CAST(@TotalAudits AS nvarchar(10)) + N' audit object(s) and ' + CAST(@TotalSpecs AS nvarchar(10)) + N' audit specification(s) exist, but no audit is enabled (is_state_enabled = 0), so no audit records are written.';
    END
    ELSE IF @EffectiveSpecs = 0
    BEGIN
        SET @Score = 1;
        SET @Finding = @Finding + N'Instance [' + @DatabaseQueried + N']: audit(s) ' + ISNULL(@EnabledAuditNames, N'n/a') + N' are enabled, but no enabled server or database audit specification is bound to an enabled audit (' + CAST(@TotalSpecs AS nvarchar(10)) + N' specification(s) found), so no sensitive actions are collected.';
    END
    ELSE IF @CoveredCount < @RequiredCount
    BEGIN
        SET @Score = 2;
        SET @Finding = @Finding + N'Instance [' + @DatabaseQueried + N']: enabled audit(s) ' + ISNULL(@EnabledAuditNames, N'n/a') + N' with specification(s) ' + ISNULL(@EffectiveSpecNames, N'n/a') + N' cover ' + CAST(@CoveredCount AS nvarchar(10)) + N' of ' + CAST(@RequiredCount AS nvarchar(10)) + N' required sensitive action groups. Missing: ' + ISNULL(@MissingGroups, N'n/a') + N'.';
    END
    ELSE
    BEGIN
        SET @Score = 3;
        SET @Finding = @Finding + N'Instance [' + @DatabaseQueried + N']: enabled audit(s) ' + ISNULL(@EnabledAuditNames, N'n/a') + N' with specification(s) ' + ISNULL(@EffectiveSpecNames, N'n/a') + N' cover all ' + CAST(@RequiredCount AS nvarchar(10)) + N' required sensitive action groups.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #RequiredGroups;
DROP TABLE #CoveredGroups;
DROP TABLE #Audits;
DROP TABLE #Specs;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;