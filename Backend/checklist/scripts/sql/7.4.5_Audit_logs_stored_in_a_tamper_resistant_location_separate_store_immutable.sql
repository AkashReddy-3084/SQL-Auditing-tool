-- Checklist: Audit logs stored in a tamper-resistant location (separate store / immutable)
-- Scope: SERVER
-- Scoring: 
-- 0: No server audits configured, or audit files stored on the same volume as default data/log paths, or on_failure is CONTINUE.
-- 1: Server audit configured and enabled, but stored on the same volume as data/logs, or on_failure is CONTINUE.
-- 2: Server audit configured, enabled, stored on a separate volume from data/logs, and on_failure is SHUTDOWN. (Capped at 2: true immutability requires OS/SIEM verification).
-- 3: Azure SQL Database audit enabled (logs routed to tamper-resistant Azure Storage/Log Analytics).

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

SET @DatabaseQueried = 'master';

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    DECLARE @AuditEnabled INT = 0;
    SELECT @AuditEnabled = COUNT(*) FROM sys.database_audit_specifications WHERE is_state_enabled = 1;
    
    IF @AuditEnabled > 0
    BEGIN
        SET @Score = 3;
        SET @Finding = 'Azure SQL Database audit is enabled. Logs are automatically routed to Azure Storage/Log Analytics, which provides tamper-resistant, immutable storage.';
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No database audit specifications are enabled. Audit logs are not being captured.';
    END
END
ELSE -- SQL Server / Azure SQL MI
BEGIN
    IF OBJECT_ID('sys.server_audites') IS NOT NULL
    BEGIN
        DECLARE @DefaultDataPath NVARCHAR(256) = CONVERT(NVARCHAR(256), SERVERPROPERTY('InstanceDefaultDataPath'));
        DECLARE @DefaultLogPath NVARCHAR(256) = CONVERT(NVARCHAR(256), SERVERPROPERTY('InstanceDefaultLogPath'));
        DECLARE @AuditCount INT = 0;
        DECLARE @EnabledCount INT = 0;
        DECLARE @SeparatePathCount INT = 0;
        DECLARE @ShutdownCount INT = 0;

        SELECT 
            @AuditCount = COUNT(*),
            @EnabledCount = SUM(CASE WHEN is_state_enabled = 1 THEN 1 ELSE 0 END),
            @SeparatePathCount = SUM(CASE 
                WHEN audit_file_path IS NOT NULL 
                AND (LEFT(audit_file_path, 2) <> LEFT(@DefaultDataPath, 2) OR LEFT(audit_file_path, 2) <> LEFT(@DefaultLogPath, 2) OR LEFT(audit_file_path, 2) = '\\') 
                THEN 1 ELSE 0 END),
            @ShutdownCount = SUM(CASE WHEN on_failure = 1 THEN 1 ELSE 0 END)
        FROM sys.server_audites;

        IF @AuditCount = 0
        BEGIN
            SET @Score = 0;
            SET @Finding = 'No server audits are configured.';
        END
        ELSE IF @EnabledCount = 0
        BEGIN
            SET @Score = 0;
            SET @Finding = 'Server audits are configured but none are enabled.';
        END
        ELSE IF @SeparatePathCount = 0 AND @ShutdownCount = 0
        BEGIN
            SET @Score = 0;
            SET @Finding = 'Audit logs are stored on the same volume as data/log files and on_failure is set to CONTINUE.';
        END
        ELSE IF @SeparatePathCount > 0 AND @ShutdownCount = 0
        BEGIN
            SET @Score = 1;
            SET @Finding = 'Audit logs are stored on a separate volume, but on_failure is set to CONTINUE.';
        END
        ELSE IF @SeparatePathCount > 0 AND @ShutdownCount > 0
        BEGIN
            SET @Score = 2;
            SET @Finding = 'Audit logs are stored on a separate volume and on_failure is set to SHUTDOWN. True immutability requires OS/SIEM verification.';
        END
        ELSE
        BEGIN
            SET @Score = 1;
            SET @Finding = 'Audit logs are configured, but path separation or failure behavior needs review.';
        END
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'Server audit metadata is unavailable on this platform.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;