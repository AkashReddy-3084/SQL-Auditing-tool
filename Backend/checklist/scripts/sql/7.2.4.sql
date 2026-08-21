/* Checklist 7.2.4 - Access control changes logged and reviewable
   Read-only: inspects audit metadata only. */
SET NOCOUNT ON;

DECLARE @EngineEdition       INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @IsDbScopedPlatform  BIT = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 5 THEN 1 ELSE 0 END;
DECLARE @CanViewDefinition   INT = ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW ANY DEFINITION'), 0);

DECLARE @Result   NVARCHAR(20);
DECLARE @Score    INT;
DECLARE @Finding  NVARCHAR(4000);

DECLARE @ServerAuditCount        INT = 0;
DECLARE @EnabledServerAuditCount INT = 0;
DECLARE @DdlTriggerCount         INT = 0;
DECLARE @RequiredCount           INT = 0;
DECLARE @ActiveCovered           INT = 0;
DECLARE @AnyCovered              INT = 0;
DECLARE @MissingList             NVARCHAR(2000) = NULL;
DECLARE @AuditList               NVARCHAR(2000) = NULL;

IF OBJECT_ID('tempdb..#RequiredGroups') IS NOT NULL DROP TABLE #RequiredGroups;
IF OBJECT_ID('tempdb..#Covered')        IS NOT NULL DROP TABLE #Covered;

CREATE TABLE #RequiredGroups
(
    GroupName     NVARCHAR(128) NOT NULL PRIMARY KEY,
    IsServerLevel BIT           NOT NULL
);

INSERT INTO #RequiredGroups (GroupName, IsServerLevel)
VALUES ('SERVER_PERMISSION_CHANGE_GROUP',          1),
       ('SERVER_ROLE_MEMBER_CHANGE_GROUP',         1),
       ('SERVER_PRINCIPAL_CHANGE_GROUP',           1),
       ('DATABASE_PERMISSION_CHANGE_GROUP',        0),
       ('DATABASE_ROLE_MEMBER_CHANGE_GROUP',       0),
       ('DATABASE_PRINCIPAL_CHANGE_GROUP',         0),
       ('DATABASE_OBJECT_PERMISSION_CHANGE_GROUP', 0),
       ('SCHEMA_OBJECT_PERMISSION_CHANGE_GROUP',   0);

CREATE TABLE #Covered
(
    Scope         NVARCHAR(20)  NOT NULL,
    DatabaseName  NVARCHAR(128) NULL,
    SpecName      NVARCHAR(128) NOT NULL,
    GroupName     NVARCHAR(128) NOT NULL,
    AuditName     NVARCHAR(128) NULL,
    AuditEnabled  BIT           NOT NULL,
    SpecEnabled   BIT           NOT NULL,
    Destination   NVARCHAR(128) NULL
);

IF @IsDbScopedPlatform = 0
BEGIN
    /* Instance-level platforms: SQL Server, Azure SQL Managed Instance */
    BEGIN TRY
        SELECT @ServerAuditCount = COUNT(*) FROM sys.server_audits;

        SELECT @EnabledServerAuditCount = COUNT(*)
        FROM sys.server_audits
        WHERE is_state_enabled = 1;

        SELECT @AuditList = STUFF(
            (
                SELECT N', ' + sa.name + N' (' + sa.type_desc + N', '
                       + CASE WHEN sa.is_state_enabled = 1 THEN N'enabled' ELSE N'disabled' END + N')'
                FROM sys.server_audits AS sa
                ORDER BY sa.name
                FOR XML PATH(''), TYPE
            ).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');
    END TRY
    BEGIN CATCH
        SET @ServerAuditCount = 0;
    END CATCH;

    BEGIN TRY
        SELECT @DdlTriggerCount = COUNT(DISTINCT st.object_id)
        FROM sys.server_triggers AS st
        INNER JOIN sys.server_trigger_events AS ste
            ON ste.object_id = st.object_id
        WHERE st.is_disabled = 0
          AND ste.type_desc IN ('CREATE_LOGIN', 'ALTER_LOGIN', 'DROP_LOGIN',
                                'GRANT_SERVER', 'DENY_SERVER', 'REVOKE_SERVER',
                                'ADD_SERVER_ROLE_MEMBER', 'DROP_SERVER_ROLE_MEMBER',
                                'ADD_ROLE_MEMBER', 'DROP_ROLE_MEMBER');
    END TRY
    BEGIN CATCH
        SET @DdlTriggerCount = 0;
    END CATCH;

    BEGIN TRY
        INSERT INTO #Covered (Scope, DatabaseName, SpecName, GroupName, AuditName, AuditEnabled, SpecEnabled, Destination)
        SELECT 'SERVER',
               NULL,
               sas.name,
               sasd.audit_action_name,
               sa.name,
               ISNULL(sa.is_state_enabled, 0),
               ISNULL(sas.is_state_enabled, 0),
               sa.type_desc
        FROM sys.server_audit_specification_details AS sasd
        INNER JOIN sys.server_audit_specifications AS sas
            ON sas.server_specification_id = sasd.server_specification_id
        LEFT JOIN sys.server_audits AS sa
            ON sa.audit_guid = sas.audit_guid
        WHERE sasd.audit_action_name IN (SELECT GroupName FROM #RequiredGroups);
    END TRY
    BEGIN CATCH
        /* Insufficient permission to read server audit metadata - reported in the finding. */
        SET @ServerAuditCount = @ServerAuditCount;
    END CATCH;

    /* Enumerate database audit specifications in every accessible online database. */
    DECLARE @DbName SYSNAME;
    DECLARE @Sql    NVARCHAR(MAX);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.state = 0
          AND d.database_id <> 2
          AND d.source_database_id IS NULL
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'SELECT ''DATABASE'', @p_db, das.name, dasd.audit_action_name, sa.name, '
                     + N'ISNULL(sa.is_state_enabled, 0), ISNULL(das.is_state_enabled, 0), sa.type_desc '
                     + N'FROM ' + QUOTENAME(@DbName) + N'.sys.database_audit_specification_details AS dasd '
                     + N'INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.database_audit_specifications AS das '
                     + N'    ON das.database_specification_id = dasd.database_specification_id '
                     + N'LEFT JOIN sys.server_audits AS sa '
                     + N'    ON sa.audit_guid = das.audit_guid '
                     + N'WHERE dasd.audit_action_name IN (SELECT GroupName FROM #RequiredGroups);';

            INSERT INTO #Covered (Scope, DatabaseName, SpecName, GroupName, AuditName, AuditEnabled, SpecEnabled, Destination)
            EXEC sp_executesql @Sql, N'@p_db NVARCHAR(128)', @p_db = @DbName;
        END TRY
        BEGIN CATCH
            /* Database unavailable or not readable - skip it. */
            SET @DbName = @DbName;
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END
ELSE
BEGIN
    /* Azure SQL Database: only database-scoped audit metadata is visible. */
    BEGIN TRY
        INSERT INTO #Covered (Scope, DatabaseName, SpecName, GroupName, AuditName, AuditEnabled, SpecEnabled, Destination)
        SELECT 'DATABASE',
               DB_NAME(),
               das.name,
               dasd.audit_action_name,
               NULL,
               1,
               ISNULL(das.is_state_enabled, 0),
               N'AZURE_DATABASE_AUDIT'
        FROM sys.database_audit_specification_details AS dasd
        INNER JOIN sys.database_audit_specifications AS das
            ON das.database_specification_id = dasd.database_specification_id
        WHERE dasd.audit_action_name IN (SELECT GroupName FROM #RequiredGroups);
    END TRY
    BEGIN CATCH
        SET @EngineEdition = @EngineEdition;
    END CATCH;
END

SELECT @RequiredCount = COUNT(*)
FROM #RequiredGroups
WHERE @IsDbScopedPlatform = 0
   OR IsServerLevel = 0;

SELECT @ActiveCovered = COUNT(DISTINCT c.GroupName)
FROM #Covered AS c
INNER JOIN #RequiredGroups AS rg
    ON rg.GroupName = c.GroupName
WHERE c.SpecEnabled = 1
  AND c.AuditEnabled = 1
  AND (@IsDbScopedPlatform = 0 OR rg.IsServerLevel = 0);

SELECT @AnyCovered = COUNT(DISTINCT c.GroupName)
FROM #Covered AS c
INNER JOIN #RequiredGroups AS rg
    ON rg.GroupName = c.GroupName
WHERE @IsDbScopedPlatform = 0
   OR rg.IsServerLevel = 0;

SELECT @MissingList = STUFF(
    (
        SELECT N', ' + rg.GroupName
        FROM #RequiredGroups AS rg
        WHERE (@IsDbScopedPlatform = 0 OR rg.IsServerLevel = 0)
          AND NOT EXISTS
          (
              SELECT 1
              FROM #Covered AS c
              WHERE c.GroupName = rg.GroupName
                AND c.SpecEnabled = 1
                AND c.AuditEnabled = 1
          )
        ORDER BY rg.GroupName
        FOR XML PATH(''), TYPE
    ).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

IF @RequiredCount > 0 AND @ActiveCovered >= @RequiredCount
    SET @Score = 3;
ELSE IF @ActiveCovered > 0
    SET @Score = 2;
ELSE IF @AnyCovered > 0 OR @DdlTriggerCount > 0 OR @ServerAuditCount > 0
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding =
      N'Platform engine edition ' + CAST(@EngineEdition AS NVARCHAR(10))
    + CASE WHEN @IsDbScopedPlatform = 1
           THEN N' (Azure SQL Database - only database-scoped audit metadata is visible; server-level auditing configured in Azure is not exposed to T-SQL)'
           ELSE N'' END
    + N'. Server audits defined: ' + CAST(@ServerAuditCount AS NVARCHAR(10))
    + N' (enabled: ' + CAST(@EnabledServerAuditCount AS NVARCHAR(10)) + N').'
    + N' Access-control audit action groups actively captured by an enabled audit and enabled specification: '
    + CAST(@ActiveCovered AS NVARCHAR(10)) + N' of ' + CAST(@RequiredCount AS NVARCHAR(10)) + N'.'
    + CASE WHEN @AnyCovered > @ActiveCovered
           THEN N' A further ' + CAST(@AnyCovered - @ActiveCovered AS NVARCHAR(10))
                + N' required group(s) are referenced only by disabled audits or disabled specifications.'
           ELSE N'' END
    + N' Enabled security DDL triggers: ' + CAST(@DdlTriggerCount AS NVARCHAR(10)) + N'.'
    + CASE WHEN @AuditList IS NOT NULL THEN N' Audits: ' + @AuditList + N'.'
           WHEN @IsDbScopedPlatform = 0 THEN N' Audits: none defined.'
           ELSE N'' END
    + CASE WHEN @MissingList IS NOT NULL
           THEN N' Missing groups: ' + @MissingList + N'.'
           ELSE N' All required access-control action groups are covered and reviewable via the audit destination.' END
    + CASE WHEN @CanViewDefinition = 0
           THEN N' NOTE: the auditing connection lacks VIEW ANY DEFINITION, so audit metadata may be incomplete.'
           ELSE N'' END;

SET @Finding = LEFT(@Finding, 4000);

IF OBJECT_ID('tempdb..#RequiredGroups') IS NOT NULL DROP TABLE #RequiredGroups;
IF OBJECT_ID('tempdb..#Covered')        IS NOT NULL DROP TABLE #Covered;

SELECT @Result   AS Result,
       @Score    AS Score,
       N'SERVER' AS DatabaseQueried,
       @Finding  AS Finding;