-- Checklist: Access control changes logged and reviewable
-- Scope: SERVER
-- Scoring: 2 = SQL Audit or trigger evidence captures principal/role/permission actions; 1 = partial logging evidence; 0 = no logging evidence
-- NOTE: Automated evidence only; retention and reviewability require human review.

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'Access-control logging metadata could not be evaluated';
DECLARE @ServerAudits INT = 0;
DECLARE @AuditSpecs INT = 0;
DECLARE @AclActions INT = 0;
DECLARE @ServerTriggers INT = 0;
DECLARE @DdlDbTriggers INT = 0;

BEGIN TRY
    SELECT @ServerAudits = COUNT(*) FROM sys.server_audits;
    SELECT @AuditSpecs = COUNT(*) FROM sys.server_audit_specifications;
    SELECT @AclActions = COUNT(*) FROM sys.server_audit_specification_details WHERE audit_action_name LIKE '%PRINCIPAL%' OR audit_action_name LIKE '%ROLE%' OR audit_action_name LIKE '%PERMISSION%' OR audit_action_name LIKE '%LOGIN%';
    SELECT @ServerTriggers = COUNT(*) FROM sys.server_triggers WHERE is_disabled = 0;
    SELECT @DdlDbTriggers = COUNT(*) FROM sys.triggers WHERE parent_class = 0 AND is_disabled = 0;
    SET @Score = CASE WHEN @ServerAudits > 0 AND @AuditSpecs > 0 AND @AclActions > 0 THEN 2 WHEN @AuditSpecs > 0 OR @AclActions > 0 OR @ServerTriggers > 0 OR @DdlDbTriggers > 0 THEN 1 ELSE 0 END;
    SET @Finding = N'server_audits=' + CONVERT(NVARCHAR(20), @ServerAudits) + N', audit_specs=' + CONVERT(NVARCHAR(20), @AuditSpecs) + N', acl_audit_actions=' + CONVERT(NVARCHAR(20), @AclActions) + N', server_triggers=' + CONVERT(NVARCHAR(20), @ServerTriggers) + N', ddl_db_triggers=' + CONVERT(NVARCHAR(20), @DdlDbTriggers);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read access-control logging metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;