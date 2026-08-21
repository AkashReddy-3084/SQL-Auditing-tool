-- Checklist: Regular access reviews scheduled and documented
-- Scope: SERVER
-- Scoring: 0: No proxy evidence found. 1: Audit configured but disabled. 2: Proxy evidence found (audit tracking enabled), but scheduling/documentation requires human verification. 3: Not achievable automatically.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EnabledAudits INT;
DECLARE @DisabledAudits INT;

SET @DatabaseQueried = 'master';

-- Count enabled server-level audit specifications
SELECT @EnabledAudits = COUNT(*)
FROM sys.server_audit sa
JOIN sys.server_audit_specifications sas ON sa.audit_guid = sas.audit_guid
WHERE sa.is_enabled = 1 AND sas.is_enabled = 1;

-- Count disabled server-level audit specifications
SELECT @DisabledAudits = COUNT(*)
FROM sys.server_audit sa
JOIN sys.server_audit_specifications sas ON sa.audit_guid = sas.audit_guid
WHERE sa.is_enabled = 0 OR sas.is_enabled = 0;

-- Fallback to database audit specifications if server specs are empty
IF @EnabledAudits = 0 AND @DisabledAudits = 0
BEGIN
    SELECT @EnabledAudits = COUNT(*)
    FROM sys.database_audit_specifications das
    WHERE das.is_enabled = 1;

    SELECT @DisabledAudits = COUNT(*)
    FROM sys.database_audit_specifications das
    WHERE das.is_enabled = 0;
END

IF @EnabledAudits > 0
BEGIN
    SET @Score = 2;
    SET @Finding = 'Proxy evidence found: ' + CAST(@EnabledAudits AS NVARCHAR(10)) + ' audit specification(s) enabled. NOTE: This script provides automated evidence. Full compliance requires human review.';
END
ELSE IF @DisabledAudits > 0
BEGIN
    SET @Score = 1;
    SET @Finding = 'Partial evidence: ' + CAST(@DisabledAudits AS NVARCHAR(10)) + ' audit specification(s) configured but disabled.';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = 'No audit specifications or proxy evidence found for access review tracking.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;