-- Checklist: Data access to sensitive tables auditable (who accessed what, when)
-- Scope: SERVER
-- Scoring: 3 = database audit specs, DML audit actions, enabled audits, and sensitive-column classifications are all present; 2 = at least two evidence categories are present; 1 = one category is present; 0 = no evidence or a source is unavailable
-- NOTE: Automated evidence confirms audit configuration and classifications; actual audit-event capture and retention require human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'Audit and sensitivity-classification evidence unavailable';
DECLARE @DatabaseAuditSpecCount INT = 0;
DECLARE @DmlAuditActionCount INT = 0;
DECLARE @EnabledAuditCount INT = 0;
DECLARE @ClassifiedColumnCount INT = 0;
DECLARE @EvidenceCategoryCount INT = 0;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT @DatabaseAuditSpecCount = COUNT(*)
    FROM sys.database_audit_specifications;

    SELECT @DmlAuditActionCount = COUNT(*)
    FROM sys.database_audit_specification_details
    WHERE audit_action_name IN (N'SELECT', N'INSERT', N'UPDATE', N'DELETE');

    SELECT @EnabledAuditCount = COUNT(*)
    FROM sys.server_audits
    WHERE is_state_enabled = 1;

    SELECT @ClassifiedColumnCount = COUNT(*)
    FROM sys.sensitivity_classifications;
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

SET @EvidenceCategoryCount =
    CASE WHEN @DatabaseAuditSpecCount > 0 THEN 1 ELSE 0 END
  + CASE WHEN @DmlAuditActionCount > 0 THEN 1 ELSE 0 END
  + CASE WHEN @EnabledAuditCount > 0 THEN 1 ELSE 0 END
  + CASE WHEN @ClassifiedColumnCount > 0 THEN 1 ELSE 0 END;

SET @Score = CASE
    WHEN @ReadError = 1 THEN 0
    WHEN @EvidenceCategoryCount >= 4 THEN 3
    WHEN @EvidenceCategoryCount >= 2 THEN 2
    WHEN @EvidenceCategoryCount = 1 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'database audit specifications = ', @DatabaseAuditSpecCount,
    N'; DML audit actions = ', @DmlAuditActionCount,
    N'; enabled server audits = ', @EnabledAuditCount,
    N'; classified sensitive columns = ', @ClassifiedColumnCount,
    CASE WHEN @ReadError = 1 THEN N'; one or more audit sources could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
