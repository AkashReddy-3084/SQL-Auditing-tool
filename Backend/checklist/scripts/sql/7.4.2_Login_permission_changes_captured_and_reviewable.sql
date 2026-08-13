-- Checklist: Login/permission changes captured and reviewable
-- Scope: SERVER
-- Scoring: 3=Server audit enabled with principal/role change action groups; 2=Audit enabled but missing security groups or uses Extended Events; 1=Default trace only; 0=No auditing mechanism configured
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @AuditEnabled BIT = 0;
DECLARE @SecurityGroupsFound INT = 0;
DECLARE @XESessionFound BIT = 0;
DECLARE @DefaultTraceFound BIT = 0;

-- 1. Check if any server audit is enabled
IF OBJECT_ID('sys.server_audits') IS NOT NULL
BEGIN
    SELECT @AuditEnabled = MAX(is_state_enabled) FROM sys.server_audits;
END

-- 2. Check if enabled audit specifications cover login/permission changes
IF @AuditEnabled = 1 AND OBJECT_ID('sys.server_audit_specification_details') IS NOT NULL AND OBJECT_ID('sys.dm_audit_actions') IS NOT NULL
BEGIN
    SELECT @SecurityGroupsFound = COUNT(*)
    FROM sys.server_audit_specifications AS spec
    JOIN sys.server_audit_specification_details AS det ON spec.audit_specification_id = det.audit_specification_id
    JOIN sys.dm_audit_actions AS act ON det.audit_action_id = act.action_id
    WHERE spec.is_enabled = 1
      AND act.name IN (
          'SERVER_PRINCIPAL_CHANGE_GROUP',
          'SERVER_ROLE_MEMBER_CHANGE_GROUP',
          'DATABASE_PRINCIPAL_CHANGE_GROUP',
          'DATABASE_ROLE_MEMBER_CHANGE_GROUP',
          'ADD_MEMBER_GROUP',
          'DROP_MEMBER_GROUP'
      );
END

-- 3. Fallback: Check for Extended Events capturing security changes
IF OBJECT_ID('sys.server_event_sessions') IS NOT NULL
BEGIN
    SELECT @XESessionFound = CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END
    FROM sys.server_event_sessions AS ses
    JOIN sys.server_event_session_actions AS act ON ses.event_session_id = act.event_session_id
    WHERE ses.create_date IS NOT NULL
      AND act.name IN ('collect_principal_name', 'collect_permissions');
END

-- 4. Fallback: Check for default trace (captures some changes but not compliance-grade)
IF OBJECT_ID('sys.traces') IS NOT NULL
BEGIN
    SELECT @DefaultTraceFound = CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END
    FROM sys.traces WHERE is_default = 1;
END

-- Determine score based on evidence hierarchy
IF @SecurityGroupsFound > 0
    SET @Score = 3;
ELSE IF @AuditEnabled = 1
    SET @Score = 2;
ELSE IF @XESessionFound = 1
    SET @Score = 2;
ELSE IF @DefaultTraceFound = 1
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;