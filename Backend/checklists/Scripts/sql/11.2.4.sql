-- Checklist: No manual production changes - all via pipeline
-- Scope: SERVER
-- Scoring: 2 = object-change and DDL-audit evidence exists; 1 = partial change-tracking evidence; 0 = no evidence
-- NOTE: Automated evidence only; proving all production changes use a pipeline requires deployment records and human review.

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'Production-change metadata could not be evaluated';
DECLARE @ModifiedObjects INT = 0;
DECLARE @ObjectsTotal INT = 0;
DECLARE @DdlTriggers INT = 0;
DECLARE @DdlAuditActions INT = 0;

BEGIN TRY
    SELECT @ModifiedObjects = COUNT(*) FROM sys.objects WHERE is_ms_shipped = 0 AND modify_date > create_date;
    SELECT @ObjectsTotal = COUNT(*) FROM sys.objects WHERE is_ms_shipped = 0;
    SELECT @DdlTriggers = COUNT(*) FROM sys.triggers WHERE parent_class = 0 AND is_disabled = 0;
    SELECT @DdlAuditActions = COUNT(*) FROM sys.server_audit_specification_details WHERE audit_action_name LIKE '%SCHEMA%' OR audit_action_name LIKE '%DATABASE_OBJECT%';
    SET @Score = CASE WHEN @ObjectsTotal > 0 AND @DdlAuditActions > 0 THEN 2 WHEN @ModifiedObjects > 0 OR @DdlTriggers > 0 OR @DdlAuditActions > 0 THEN 1 ELSE 0 END;
    SET @Finding = N'modified_objects=' + CONVERT(NVARCHAR(20), @ModifiedObjects) + N', objects_total=' + CONVERT(NVARCHAR(20), @ObjectsTotal) + N', ddl_triggers=' + CONVERT(NVARCHAR(20), @DdlTriggers) + N', ddl_audit_actions=' + CONVERT(NVARCHAR(20), @DdlAuditActions);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read production-change metadata: ' + ERROR_MESSAGE();
END CATCH;
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;