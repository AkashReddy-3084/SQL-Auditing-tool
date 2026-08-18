-- Checklist: Audit logs retained per compliance requirement
-- Scope: SERVER
-- Scoring: 0=No audits configured; 1=Audits configured but disabled; 2=Audits enabled but retention settings (file count/size) are 0/unconfigured; 3=Audits enabled with explicit retention settings (file count/size > 0)

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: Audit retention is managed via Azure Portal/ARM, not T-SQL.
    DECLARE @AuditEnabled INT = 0;
    SELECT @AuditEnabled = MAX(is_enabled) FROM sys.database_audit_specifications;
    
    IF OBJECT_ID('sys.dm_db_audit_status') IS NOT NULL
    BEGIN
        SELECT @AuditEnabled = MAX(is_enabled) FROM sys.dm_db_audit_status;
    END

    SET @Score = CASE WHEN @AuditEnabled = 1 THEN 2 ELSE 0 END;
    SET @Finding = CASE WHEN @AuditEnabled = 1 THEN 'Audit enabled. Retention policy managed via Azure Portal/ARM (not queryable via T-SQL).' ELSE 'No audit configurations found.' END;
END
ELSE
BEGIN
    CREATE TABLE #AuditStatus (
        AuditName NVARCHAR(128),
        IsEnabled BIT,
        AuditFileCount INT,
        AuditFileSize BIGINT,
        AuditFilePath NVARCHAR(260)
    );

    INSERT INTO #AuditStatus
    SELECT
        sa.name,
        CASE WHEN das.audit_id IS NOT NULL THEN 1 ELSE 0 END,
        sa.audit_file_count,
        sa.audit_file_size,
        sa.audit_file_path
    FROM sys.server_audits sa
    LEFT JOIN sys.dm_os_server_audit_status das ON sa.audit_guid = das.audit_guid;

    IF NOT EXISTS (SELECT 1 FROM #AuditStatus)
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No server audits configured.';
    END
    ELSE
    BEGIN
        DECLARE @DisabledAudits NVARCHAR(MAX) = '';
        DECLARE @EnabledNoRetention NVARCHAR(MAX) = '';
        DECLARE @EnabledWithRetention NVARCHAR(MAX) = '';

        SELECT @DisabledAudits = STRING_AGG(AuditName, ', ') FROM #AuditStatus WHERE IsEnabled = 0;
        SELECT @EnabledNoRetention = STRING_AGG(AuditName, ', ') FROM #AuditStatus WHERE IsEnabled = 1 AND (AuditFileCount = 0 AND AuditFileSize = 0);
        SELECT @EnabledWithRetention = STRING_AGG(AuditName, ', ') FROM #AuditStatus WHERE IsEnabled = 1 AND (AuditFileCount > 0 OR AuditFileSize > 0);

        IF @EnabledWithRetention IS NOT NULL AND @DisabledAudits IS NULL AND @EnabledNoRetention IS NULL
        BEGIN
            SET @Score = 3;
            SET @Finding = 'All audits enabled with explicit retention settings: ' + @EnabledWithRetention;
        END
        ELSE IF @EnabledWithRetention IS NOT NULL OR @EnabledNoRetention IS NOT NULL
        BEGIN
            SET @Score = 2;
            SET @Finding = 'Audits enabled: ' + ISNULL(@EnabledWithRetention, 'None') + '; Retention not configured: ' + ISNULL(@EnabledNoRetention, 'None') + '; Disabled: ' + ISNULL(@DisabledAudits, 'None');
        END
        ELSE
        BEGIN
            SET @Score = 1;
            SET @Finding = 'Audits configured but disabled: ' + @DisabledAudits;
        END
    END
    DROP TABLE #AuditStatus;
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;