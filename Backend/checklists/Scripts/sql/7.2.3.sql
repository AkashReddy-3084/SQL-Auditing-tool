-- Checklist: Audit trail for changes to financial-relevant data
-- Scope: DATABASE
-- Scoring: 3 = financial columns and at least two audit mechanisms are evidenced; 2 = financial columns and one audit mechanism are evidenced; 1 = audit or financial evidence exists without that combination; 0 = no evidence or evidence is unavailable
-- NOTE: Automated evidence uses schema and trigger proxies; audit retention, coverage, and business-critical financial scope require human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Financial audit-trail evidence unavailable';
DECLARE @TemporalTableCount INT = 0;
DECLARE @AuditTriggerCount INT = 0;
DECLARE @AuditTableCount INT = 0;
DECLARE @FinancialColumnCount INT = 0;
DECLARE @AuditMechanismCount INT = 0;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT @TemporalTableCount = COUNT(*)
    FROM sys.tables
    WHERE temporal_type <> 0;

    SELECT @AuditTriggerCount = COUNT(*)
    FROM sys.triggers AS t
    INNER JOIN sys.tables AS tb ON tb.object_id = t.parent_id
    WHERE t.is_disabled = 0
      AND tb.is_ms_shipped = 0;

    SELECT @AuditTableCount = COUNT(*)
    FROM sys.tables
    WHERE is_ms_shipped = 0
      AND (name LIKE N'%audit%' OR name LIKE N'%history%' OR name LIKE N'%[_]log');

    SELECT @FinancialColumnCount = COUNT(*)
    FROM sys.tables AS t
    INNER JOIN sys.columns AS c ON c.object_id = t.object_id
    INNER JOIN sys.types AS ty ON ty.user_type_id = c.user_type_id
    WHERE t.is_ms_shipped = 0
      AND ty.name IN (N'money', N'smallmoney', N'decimal', N'numeric');
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

SET @AuditMechanismCount =
    CASE WHEN @TemporalTableCount > 0 THEN 1 ELSE 0 END
  + CASE WHEN @AuditTriggerCount > 0 THEN 1 ELSE 0 END
  + CASE WHEN @AuditTableCount > 0 THEN 1 ELSE 0 END;

SET @Score = CASE
    WHEN @ReadError = 1 THEN 0
    WHEN @FinancialColumnCount > 0 AND @AuditMechanismCount >= 2 THEN 3
    WHEN @FinancialColumnCount > 0 AND @AuditMechanismCount = 1 THEN 2
    WHEN @FinancialColumnCount > 0 OR @AuditMechanismCount > 0 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'temporal tables = ', @TemporalTableCount,
    N'; enabled audit triggers = ', @AuditTriggerCount,
    N'; audit/history/log tables = ', @AuditTableCount,
    N'; financial columns = ', @FinancialColumnCount,
    CASE WHEN @ReadError = 1 THEN N'; one or more audit sources could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
