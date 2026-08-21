/* Checklist 7.4.3 - Data access to sensitive tables auditable (who accessed what, when) */
/* Read-only. Verifies that an enabled, running SQL Server Audit captures data-access actions. */
SET NOCOUNT ON;

DECLARE @Result NVARCHAR(50) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(256) = N'SERVER';
DECLARE @Finding NVARCHAR(MAX) = N'';
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

DECLARE @ServerAuditCount INT = 0;
DECLARE @ServerAuditRunning INT = 0;
DECLARE @ServerSpecCount INT = 0;
DECLARE @ServerSpecAccess INT = 0;
DECLARE @DbTotal INT = 0;
DECLARE @DbWithSpec INT = 0;
DECLARE @DbWithAccess INT = 0;
DECLARE @DbErrors INT = 0;
DECLARE @CoveredList NVARCHAR(MAX) = N'';
DECLARE @MissingList NVARCHAR(MAX) = N'';
DECLARE @AzSpecCount INT = 0;
DECLARE @AzEnabledCount INT = 0;
DECLARE @AzAccessCount INT = 0;
DECLARE @AzSpecNames NVARCHAR(MAX) = N'';
DECLARE @db SYSNAME;
DECLARE @sql NVARCHAR(MAX);
DECLARE @serverSql NVARCHAR(MAX);

BEGIN TRY

    IF @EngineEdition = 5
    BEGIN
        /* Azure SQL Database: only the current database's audit specification is visible from T-SQL. */
        SET @DatabaseQueried = DB_NAME();

        SELECT @AzSpecCount = COUNT(*) FROM sys.database_audit_specifications;

        SELECT @AzEnabledCount = COUNT(*)
        FROM sys.database_audit_specifications
        WHERE is_state_enabled = 1;

        SELECT @AzAccessCount = COUNT(DISTINCT s.database_specification_id)
        FROM sys.database_audit_specifications AS s
        INNER JOIN sys.database_audit_specification_details AS d
            ON d.database_specification_id = s.database_specification_id
        WHERE s.is_state_enabled = 1
          AND d.audit_action_name IN (N'SELECT', N'SCHEMA_OBJECT_ACCESS_GROUP');

        SELECT @AzSpecNames = @AzSpecNames
                            + CASE WHEN @AzSpecNames = N'' THEN N'' ELSE N', ' END
                            + s.name
        FROM sys.database_audit_specifications AS s
        WHERE s.is_state_enabled = 1;

        IF @AzAccessCount > 0
        BEGIN
            SET @Score = 2;
            SET @Finding = N'Azure SQL Database [' + @DatabaseQueried + N']: '
                         + CAST(@AzAccessCount AS NVARCHAR(10))
                         + N' enabled database audit specification(s) capture data-access actions (SELECT / SCHEMA_OBJECT_ACCESS_GROUP): '
                         + @AzSpecNames + N'. Reads against sensitive tables are recorded with principal and timestamp.';
        END
        ELSE
        BEGIN
            SET @Score = 1;
            SET @Finding = N'Azure SQL Database [' + @DatabaseQueried + N']: '
                         + CAST(@AzSpecCount AS NVARCHAR(10)) + N' database audit specification(s) defined, '
                         + CAST(@AzEnabledCount AS NVARCHAR(10)) + N' enabled, none capturing SELECT or SCHEMA_OBJECT_ACCESS_GROUP. '
                         + N'Server-level (logical server) auditing policy is not exposed to T-SQL and must be confirmed manually in the Azure portal.';
        END
    END
    ELSE
    BEGIN
        /* Instance-level audit configuration (dynamic SQL so Azure-incompatible objects are never resolved above). */
        SET @serverSql = N'
            SELECT @ac = COUNT(*) FROM sys.server_audits;

            SELECT @ar = COUNT(*)
            FROM sys.server_audits AS a
            INNER JOIN sys.dm_server_audit_status AS st ON st.audit_id = a.audit_id
            WHERE a.is_state_enabled = 1 AND st.status_desc = N''STARTED'';

            SELECT @sc = COUNT(*) FROM sys.server_audit_specifications WHERE is_state_enabled = 1;

            SELECT @sg = COUNT(DISTINCT s.server_specification_id)
            FROM sys.server_audit_specifications AS s
            INNER JOIN sys.server_audit_specification_details AS d
                ON d.server_specification_id = s.server_specification_id
            WHERE s.is_state_enabled = 1
              AND d.audit_action_name = N''SCHEMA_OBJECT_ACCESS_GROUP'';';

        EXEC sp_executesql @serverSql,
             N'@ac INT OUTPUT, @ar INT OUTPUT, @sc INT OUTPUT, @sg INT OUTPUT',
             @ac = @ServerAuditCount OUTPUT,
             @ar = @ServerAuditRunning OUTPUT,
             @sc = @ServerSpecCount OUTPUT,
             @sg = @ServerSpecAccess OUTPUT;

        CREATE TABLE #DbAudit
        (
            DbName SYSNAME NOT NULL,
            SpecCount INT NOT NULL,
            AccessSpecCount INT NOT NULL,
            QueryFailed BIT NOT NULL
        );

        DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT d.name
            FROM sys.databases AS d
            WHERE d.database_id > 4
              AND d.state_desc = N'ONLINE'
              AND d.source_database_id IS NULL
              AND d.is_distributor = 0
              AND HAS_DBACCESS(d.name) = 1;

        OPEN db_cur;
        FETCH NEXT FROM db_cur INTO @db;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @sql = N'USE ' + QUOTENAME(@db) + N';
                INSERT INTO #DbAudit (DbName, SpecCount, AccessSpecCount, QueryFailed)
                SELECT @dbname,
                       (SELECT COUNT(*) FROM sys.database_audit_specifications),
                       (SELECT COUNT(DISTINCT s.database_specification_id)
                        FROM sys.database_audit_specifications AS s
                        INNER JOIN sys.database_audit_specification_details AS d
                            ON d.database_specification_id = s.database_specification_id
                        WHERE s.is_state_enabled = 1
                          AND d.audit_action_name IN (N''SELECT'', N''SCHEMA_OBJECT_ACCESS_GROUP'')),
                       0;';

            BEGIN TRY
                EXEC sp_executesql @sql, N'@dbname SYSNAME', @dbname = @db;
            END TRY
            BEGIN CATCH
                INSERT INTO #DbAudit (DbName, SpecCount, AccessSpecCount, QueryFailed)
                VALUES (@db, 0, 0, 1);
            END CATCH

            FETCH NEXT FROM db_cur INTO @db;
        END

        CLOSE db_cur;
        DEALLOCATE db_cur;

        SELECT @DbTotal = COUNT(*),
               @DbErrors = ISNULL(SUM(CASE WHEN QueryFailed = 1 THEN 1 ELSE 0 END), 0),
               @DbWithSpec = ISNULL(SUM(CASE WHEN SpecCount > 0 THEN 1 ELSE 0 END), 0),
               @DbWithAccess = ISNULL(SUM(CASE WHEN AccessSpecCount > 0 THEN 1 ELSE 0 END), 0)
        FROM #DbAudit;

        SELECT @CoveredList = @CoveredList
                            + CASE WHEN @CoveredList = N'' THEN N'' ELSE N', ' END
                            + DbName
        FROM #DbAudit
        WHERE AccessSpecCount > 0;

        SELECT @MissingList = @MissingList
                            + CASE WHEN @MissingList = N'' THEN N'' ELSE N', ' END
                            + DbName
        FROM #DbAudit
        WHERE AccessSpecCount = 0 AND QueryFailed = 0;

        IF @ServerAuditRunning > 0 AND @ServerSpecAccess > 0
        BEGIN
            SET @Score = 3;
            SET @Finding = N'Instance-wide data-access auditing is active: '
                         + CAST(@ServerAuditRunning AS NVARCHAR(10)) + N' of '
                         + CAST(@ServerAuditCount AS NVARCHAR(10)) + N' server audit(s) enabled and STARTED, with '
                         + CAST(@ServerSpecAccess AS NVARCHAR(10))
                         + N' enabled server audit specification(s) containing SCHEMA_OBJECT_ACCESS_GROUP, so reads of every table in all '
                         + CAST(@DbTotal AS NVARCHAR(10)) + N' user database(s) are recorded with principal and timestamp.';
        END
        ELSE IF @ServerAuditRunning > 0 AND @DbTotal > 0 AND @DbWithAccess = @DbTotal
        BEGIN
            SET @Score = 2;
            SET @Finding = N'All ' + CAST(@DbTotal AS NVARCHAR(10))
                         + N' user database(s) have an enabled database audit specification capturing SELECT / SCHEMA_OBJECT_ACCESS_GROUP ('
                         + @CoveredList + N'), backed by '
                         + CAST(@ServerAuditRunning AS NVARCHAR(10))
                         + N' running server audit(s). Coverage is per-database rather than instance-wide.';
        END
        ELSE IF @ServerAuditRunning > 0 AND @DbWithAccess > 0
        BEGIN
            SET @Score = 1;
            SET @Finding = N'Data-access auditing covers only ' + CAST(@DbWithAccess AS NVARCHAR(10))
                         + N' of ' + CAST(@DbTotal AS NVARCHAR(10)) + N' user database(s). Covered: '
                         + @CoveredList + N'. Not audited for data access: '
                         + CASE WHEN @MissingList = N'' THEN N'(none)' ELSE @MissingList END
                         + N'. No enabled server audit specification with SCHEMA_OBJECT_ACCESS_GROUP exists to close the gap.';
        END
        ELSE IF @ServerAuditCount > 0 OR @ServerSpecCount > 0 OR @DbWithSpec > 0
        BEGIN
            SET @Score = 1;
            SET @Finding = N'Audit objects exist but do not deliver a data-access trail: '
                         + CAST(@ServerAuditCount AS NVARCHAR(10)) + N' server audit(s) defined of which '
                         + CAST(@ServerAuditRunning AS NVARCHAR(10)) + N' are enabled and STARTED, '
                         + CAST(@ServerSpecCount AS NVARCHAR(10)) + N' enabled server audit specification(s) ('
                         + CAST(@ServerSpecAccess AS NVARCHAR(10)) + N' with SCHEMA_OBJECT_ACCESS_GROUP), and '
                         + CAST(@DbWithAccess AS NVARCHAR(10)) + N' of ' + CAST(@DbTotal AS NVARCHAR(10))
                         + N' user database(s) with a data-access database audit specification.';
        END
        ELSE
        BEGIN
            SET @Score = 0;
            SET @Finding = N'No SQL Server Audit, server audit specification or database audit specification exists on this instance across '
                         + CAST(@DbTotal AS NVARCHAR(10))
                         + N' user database(s); reads against sensitive tables are not recorded, so who accessed what and when cannot be determined.';
        END

        IF @DbErrors > 0
            SET @Finding = @Finding + N' Note: audit metadata could not be read in '
                         + CAST(@DbErrors AS NVARCHAR(10)) + N' database(s) due to insufficient permissions or database state.';

        DROP TABLE #DbAudit;
    END

END TRY
BEGIN CATCH
    IF CURSOR_STATUS('local', 'db_cur') >= 0
    BEGIN
        CLOSE db_cur;
        DEALLOCATE db_cur;
    END

    SET @Score = 1;
    SET @Finding = N'Audit configuration could not be fully evaluated: ' + ERROR_MESSAGE()
                 + N' (error ' + CAST(ERROR_NUMBER() AS NVARCHAR(20))
                 + N'). VIEW ANY DEFINITION / CONTROL SERVER permission is required to read audit metadata; verify manually.';
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result,
       @Score AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding AS Finding;