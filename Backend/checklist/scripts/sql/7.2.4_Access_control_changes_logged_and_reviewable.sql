-- Checklist: Access control changes logged and reviewable
-- Scope: SERVER
-- Scoring: 0=No audit configured; 1=Active audit missing security change groups; 2=Audit configured but disabled; 3=Active audit covering principal/permission changes.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @AuditCount INT = 0;
DECLARE @ActiveAuditCount INT = 0;
DECLARE @SecurityGroupCount INT = 0;
DECLARE @AuditNames NVARCHAR(MAX) = '';
DECLARE @ActiveAuditNames NVARCHAR(MAX) = '';

IF @EngineEdition = 5 -- Azure SQL Database
BEGIN
    SELECT @AuditCount = COUNT(*) FROM sys.database_audit_specifications;
    SELECT @ActiveAuditCount = COUNT(*) FROM sys.database_audit_specifications WHERE is_state_enabled = 1;
    IF @AuditCount > 0
    BEGIN
        SELECT @AuditNames = STRING_AGG(name, ', ') FROM sys.database_audit_specifications;
        SELECT @ActiveAuditNames = STRING_AGG(name, ', ') FROM sys.database_audit_specifications WHERE is_state_enabled = 1;
    END
    SELECT @SecurityGroupCount = COUNT(*)
    FROM sys.database_audit_specifications
    WHERE is_state_enabled = 1
      AND audit_action_id IN ('DATABASE_PRINCIPAL_CHANGE_GROUP', 'DATABASE_PERMISSION_CHANGE_GROUP', 'DATABASE_ROLE_MEMBER_CHANGE_GROUP');
END
ELSE -- SQL Server / Azure SQL MI
BEGIN
    SELECT @AuditCount = COUNT(*) FROM sys.server_audit;
    SELECT @ActiveAuditCount = COUNT(*) FROM sys.server_audit WHERE is_state_enabled = 1;
    IF @AuditCount > 0
    BEGIN
        SELECT @AuditNames = STRING_AGG(name, ', ') FROM sys.server_audit;
        SELECT @ActiveAuditNames = STRING_AGG(name, ', ') FROM sys.server_audit WHERE is_state_enabled = 1;
    END
    SELECT @SecurityGroupCount = COUNT(*)
    FROM sys.server_audit_specifications sas
    JOIN sys.server_audit sa ON sas.audit_guid = sa.audit_guid
    WHERE sas.is_state_enabled = 1
      AND sas.audit_action_id IN ('SERVER_PRINCIPAL_CHANGE_GROUP', 'SERVER_PERMISSION_CHANGE_GROUP', 'SERVER_ROLE_MEMBER_CHANGE_GROUP', 'DATABASE_PRINCIPAL_CHANGE_GROUP', 'DATABASE_PERMISSION_CHANGE_GROUP', 'DATABASE_ROLE_MEMBER_CHANGE_GROUP');
END

SET @Score = 0;
IF @AuditCount = 0
BEGIN
    SET @Finding = 'No audit configured.';
END
ELSE IF @ActiveAuditCount = 0
BEGIN
    SET @Score = 2;
    SET @Finding = 'Audit configured but disabled: ' + ISNULL(@AuditNames, 'None');
END
ELSE IF @SecurityGroupCount = 0
BEGIN
    SET @Score = 1;
    SET @Finding = 'Active audit found but does not cover principal/permission change groups: ' + ISNULL(@ActiveAuditNames, 'None');
END
ELSE
BEGIN
    SET @Score = 3;
    SET @Finding = 'Active audit configured and logging security changes: ' + ISNULL(@ActiveAuditNames, 'None');
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;