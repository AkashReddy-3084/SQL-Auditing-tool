/*
    Checklist Item : 7.4.4 - Audit logs retained per compliance requirement
    Scope          : SERVER
    Purpose        : Read-only verification that SQL Server Audit destinations are configured to
                     retain audit log history instead of silently overwriting it.
    Safety         : Metadata SELECTs only. No DDL, no DML against user objects, no configuration
                     change. A session-local temp table is used to stage the collected metadata.
*/

SET NOCOUNT ON;

DECLARE @IsAzureSqlDb    BIT            = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 5 THEN 1 ELSE 0 END;
DECLARE @Result          NVARCHAR(10);
DECLARE @Score           INT            = 0;
DECLARE @DatabaseQueried NVARCHAR(256)  = ISNULL(CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(256)), N'(unknown server)');
DECLARE @Finding         NVARCHAR(MAX)  = N'';
DECLARE @ErrorText       NVARCHAR(2000) = NULL;
DECLARE @Sql             NVARCHAR(MAX);
DECLARE @RetentionCol    NVARCHAR(200)  = N'CAST(NULL AS INT)';

IF OBJECT_ID('tempdb..#AuditRetention') IS NOT NULL
    DROP TABLE #AuditRetention;

CREATE TABLE #AuditRetention
(
    AuditName        SYSNAME       NOT NULL,
    IsEnabled        BIT           NOT NULL,
    DestinationType  NVARCHAR(60)  NOT NULL,
    LogFilePath      NVARCHAR(260) NULL,
    MaxFileSizeMB    BIGINT        NULL,
    MaxRolloverFiles BIGINT        NULL,
    MaxFiles         INT           NULL,
    RetentionDays    INT           NULL,
    IsUnlimited      BIT           NULL
);

BEGIN TRY
    IF @IsAzureSqlDb = 1
    BEGIN
        /* Azure SQL Database exposes no server audit catalog; only the database audit specification is visible. */
        INSERT INTO #AuditRetention
            (AuditName, IsEnabled, DestinationType, LogFilePath, MaxFileSizeMB, MaxRolloverFiles, MaxFiles, RetentionDays, IsUnlimited)
        SELECT  das.name,
                das.is_state_enabled,
                N'AZURE PLATFORM AUDIT',
                NULL, NULL, NULL, NULL, NULL, NULL
        FROM sys.database_audit_specifications AS das;
    END
    ELSE
    BEGIN
        /* retention_days only exists on Managed Instance builds of sys.server_file_audits. */
        IF COL_LENGTH('sys.server_file_audits', 'retention_days') IS NOT NULL
            SET @RetentionCol = N'CAST(fa.retention_days AS INT)';

        /* Dynamic SQL so the batch still compiles where sys.server_audits is absent. */
        SET @Sql = N'
            INSERT INTO #AuditRetention
                (AuditName, IsEnabled, DestinationType, LogFilePath, MaxFileSizeMB, MaxRolloverFiles, MaxFiles, RetentionDays, IsUnlimited)
            SELECT  a.name,
                    a.is_state_enabled,
                    a.type_desc,
                    fa.log_file_path,
                    CAST(fa.max_file_size AS BIGINT),
                    CAST(fa.max_rollover_files AS BIGINT),
                    CAST(fa.max_files AS INT),
                    ' + @RetentionCol + N',
                    NULL
            FROM sys.server_audits AS a
            LEFT JOIN sys.server_file_audits AS fa
                   ON fa.audit_id = a.audit_id;';

        EXEC sys.sp_executesql @Sql;

        UPDATE #AuditRetention
        SET IsUnlimited = CASE
                              WHEN DestinationType <> N'FILE' THEN NULL
                              WHEN ISNULL(MaxRolloverFiles, 0) = 0 AND ISNULL(MaxFiles, 0) = 0 THEN 1
                              ELSE 0
                          END;
    END
END TRY
BEGIN CATCH
    SET @ErrorText = ERROR_MESSAGE();
END CATCH

DECLARE @TotalAudits    INT = (SELECT COUNT(*) FROM #AuditRetention);
DECLARE @EnabledAudits  INT = (SELECT COUNT(*) FROM #AuditRetention WHERE IsEnabled = 1);
DECLARE @RetainedAudits INT = (SELECT COUNT(*) FROM #AuditRetention
                               WHERE IsEnabled = 1
                                 AND DestinationType = N'FILE'
                                 AND (IsUnlimited = 1 OR ISNULL(RetentionDays, 0) > 0));
DECLARE @BoundedAudits  INT = (SELECT COUNT(*) FROM #AuditRetention
                               WHERE IsEnabled = 1
                                 AND DestinationType = N'FILE'
                                 AND IsUnlimited = 0
                                 AND ISNULL(RetentionDays, 0) = 0);
DECLARE @ExternalAudits INT = (SELECT COUNT(*) FROM #AuditRetention
                               WHERE IsEnabled = 1
                                 AND DestinationType <> N'FILE');

DECLARE @Detail NVARCHAR(MAX) = N'';

SELECT @Detail = @Detail
     + N'[' + AuditName + N': ' + DestinationType
     + CASE WHEN IsEnabled = 1 THEN N', enabled' ELSE N', DISABLED' END
     + CASE WHEN DestinationType = N'FILE'
            THEN N', max_rollover_files=' + CAST(ISNULL(MaxRolloverFiles, 0) AS NVARCHAR(20))
               + N', max_files='          + CAST(ISNULL(MaxFiles, 0) AS NVARCHAR(20))
               + N', max_file_size_MB='   + CAST(ISNULL(MaxFileSizeMB, 0) AS NVARCHAR(20))
               + CASE WHEN RetentionDays IS NOT NULL
                      THEN N', retention_days=' + CAST(RetentionDays AS NVARCHAR(20))
                      ELSE N'' END
               + CASE WHEN IsUnlimited = 1 THEN N', retention=UNLIMITED' ELSE N', retention=BOUNDED (logs overwritten)' END
            ELSE N'' END
     + N'] '
FROM #AuditRetention;

SET @Detail = LEFT(ISNULL(@Detail, N''), 1200);

IF @ErrorText IS NOT NULL
BEGIN
    SET @Score   = 0;
    SET @Finding = N'Audit log retention could not be evaluated because the audit metadata could not be read: '
                 + @ErrorText;
END
ELSE IF @IsAzureSqlDb = 1
BEGIN
    IF @EnabledAudits > 0
    BEGIN
        SET @Score   = 1;
        SET @Finding = N'Azure SQL Database: ' + CAST(@EnabledAudits AS NVARCHAR(10)) + N' of '
                     + CAST(@TotalAudits AS NVARCHAR(10)) + N' database audit specification(s) are enabled, but the audit log '
                     + N'retention period is held in the Azure auditing policy (storage account / Log Analytics retention days) '
                     + N'and is not exposed through T-SQL, so retention against the compliance requirement cannot be evidenced here. '
                     + N'Specifications: ' + @Detail;
    END
    ELSE
    BEGIN
        SET @Score   = 0;
        SET @Finding = N'Azure SQL Database: no enabled database audit specification was found ('
                     + CAST(@TotalAudits AS NVARCHAR(10)) + N' defined), therefore no audit log is being produced or retained.';
    END
END
ELSE IF @TotalAudits = 0
BEGIN
    SET @Score   = 0;
    SET @Finding = N'No SQL Server Audit objects are defined on this instance (sys.server_audits is empty), so no audit log is '
                 + N'produced and nothing is retained for any compliance period.';
END
ELSE IF @EnabledAudits = 0
BEGIN
    SET @Score   = 1;
    SET @Finding = CAST(@TotalAudits AS NVARCHAR(10)) + N' SQL Server Audit object(s) are defined but none are enabled, so no new '
                 + N'audit records are being written or retained. Audits: ' + @Detail;
END
ELSE IF @RetainedAudits > 0 AND @BoundedAudits = 0 AND @ExternalAudits = 0
BEGIN
    SET @Score   = 3;
    SET @Finding = N'All ' + CAST(@EnabledAudits AS NVARCHAR(10)) + N' enabled SQL Server Audit(s) write to FILE with retention '
                 + N'preserved (max_rollover_files = 0 and max_files = 0, or an explicit retention_days policy), so audit log files '
                 + N'are not overwritten and can be retained for the required compliance period. Audits: ' + @Detail;
END
ELSE IF @RetainedAudits > 0
BEGIN
    SET @Score   = 2;
    SET @Finding = CAST(@RetainedAudits AS NVARCHAR(10)) + N' enabled audit(s) retain their log files, but '
                 + CAST(@BoundedAudits AS NVARCHAR(10)) + N' enabled audit(s) use bounded rollover (older files are overwritten) and '
                 + CAST(@ExternalAudits AS NVARCHAR(10)) + N' enabled audit(s) write to a destination whose retention is not held in '
                 + N'SQL Server. Retention is therefore inconsistent across the instance. Audits: ' + @Detail;
END
ELSE
BEGIN
    SET @Score   = 1;
    SET @Finding = N'None of the ' + CAST(@EnabledAudits AS NVARCHAR(10)) + N' enabled audit(s) retain their log history in SQL Server: '
                 + CAST(@BoundedAudits AS NVARCHAR(10)) + N' use bounded rollover so older audit files are overwritten, and '
                 + CAST(@ExternalAudits AS NVARCHAR(10)) + N' write to the Windows Application/Security log or an external monitor '
                 + N'where retention is governed outside the database engine. Audits: ' + @Detail;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #AuditRetention;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;