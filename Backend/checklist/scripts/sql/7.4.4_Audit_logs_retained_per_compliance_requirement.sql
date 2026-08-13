-- Checklist: Audit logs retained per compliance requirement
-- Scope: SERVER
-- Scoring: 0 = No audit infrastructure detected; 1 = Partially configured (audit exists but disabled); 2 = Fully enabled and configured (proxy for retention capability); 3 = Not achievable via script (retention duration is a compliance policy requiring manual verification)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @AuditCount INT = 0;
DECLARE @EnabledCount INT = 0;

SELECT @AuditCount = COUNT(*), @EnabledCount = SUM(CASE WHEN is_enabled = 1 THEN 1 ELSE 0 END)
FROM sys.server_audits;

IF @AuditCount > 0 AND @EnabledCount > 0
    SET @Score = 2;
ELSE IF @AuditCount > 0
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;
-- NOTE: This script provides automated evidence. Full compliance requires human review.