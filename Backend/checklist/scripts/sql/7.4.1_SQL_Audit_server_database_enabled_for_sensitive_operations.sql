-- Checklist: SQL Audit (server/database) enabled for sensitive operations
-- Scope: SERVER
-- Scoring: 0=No enabled audit, 1=Enabled but covers 0 sensitive ops, 2=Covers 1-2 sensitive ops, 3=Covers 3+ sensitive ops
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @CoveredCount INT = 0;
DECLARE @IsEnabled BIT = 0;

-- Check server audit if available (On-prem / MI)
IF OBJECT_ID('sys.server_audit_specifications') IS NOT NULL
BEGIN
    SELECT @IsEnabled = MAX(is_state_enabled) FROM sys.server_audit_specifications;
    IF @IsEnabled = 1
    BEGIN
        SELECT @CoveredCount = COUNT(DISTINCT s.ActionName)
        FROM (VALUES ('LOGIN_FAILURES'), ('SERVER_OPERATION'), ('SCHEMA_OBJECT_CHANGE_GROUP'), 
              ('SERVER_PRINCIPAL_CHANGE_GROUP'), ('SERVER_ROLE_MEMBER_CHANGE_GROUP'), 
              ('DATABASE_PRINCIPAL_CHANGE_GROUP'), ('DATABASE_ROLE_MEMBER_CHANGE_GROUP'), 
              ('BACKUP_RESTORE_GROUP'), ('BULK_OPERATIONS_GROUP'), ('SERVER_STATE_CHANGE_GROUP')) AS s(ActionName)
        INNER JOIN sys.server_audit_specification_details d ON s.ActionName = d.audit_action_id
        INNER JOIN sys.server_audit_specifications a ON d.server_specification_id = a.server_specification_id
        WHERE a.is_state_enabled = 1;
    END
END
ELSE
BEGIN
    -- Fallback to database audit for Azure SQL DB
    SELECT @IsEnabled = MAX(is_state_enabled) FROM sys.database_audit_specifications;
    IF @IsEnabled = 1
    BEGIN
        SELECT @CoveredCount = COUNT(DISTINCT s.ActionName)
        FROM (VALUES ('LOGIN_FAILURES'), ('SCHEMA_OBJECT_CHANGE_GROUP'), 
              ('DATABASE_PRINCIPAL_CHANGE_GROUP'), ('DATABASE_ROLE_MEMBER_CHANGE_GROUP'), 
              ('BACKUP_RESTORE_GROUP'), ('BULK_OPERATIONS_GROUP')) AS s(ActionName)
        INNER JOIN sys.database_audit_specification_details d ON s.ActionName = d.audit_action_id
        INNER JOIN sys.database_audit_specifications a ON d.database_specification_id = a.database_specification_id
        WHERE a.is_state_enabled = 1;
    END
END

IF @CoveredCount >= 3 SET @Score = 3;
ELSE IF @CoveredCount >= 1 SET @Score = 2;
ELSE IF @IsEnabled = 1 SET @Score = 1;
ELSE SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;