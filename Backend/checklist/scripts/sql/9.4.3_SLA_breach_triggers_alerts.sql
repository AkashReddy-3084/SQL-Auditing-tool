-- Checklist: SLA breach triggers alerts
-- Scope: SERVER
-- Scoring: 0=No alerts/operators; 1=Exists but disabled/unlinked; 2=Enabled & linked for performance/availability metrics; 3=Fully verified SLA thresholds (capped at 2 due to business-defined nature)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

IF OBJECT_ID('msdb.dbo.sysalerts') IS NOT NULL
BEGIN
    DECLARE @AlertCount INT = 0;
    DECLARE @OperatorCount INT = 0;
    DECLARE @LinkedCount INT = 0;
    DECLARE @SlaAlertCount INT = 0;

    SELECT @AlertCount = COUNT(*) FROM msdb.dbo.sysalerts WHERE enabled = 1;
    SELECT @OperatorCount = COUNT(*) FROM msdb.dbo.sysoperators;
    
    -- Count only links where the associated alert is enabled
    SELECT @LinkedCount = COUNT(*) FROM msdb.dbo.sysalert_operator ao
    INNER JOIN msdb.dbo.sysalerts a ON ao.alert_id = a.alert_id
    WHERE a.enabled = 1;

    -- Check for SLA-related keywords in name or description (fixed column name)
    SELECT @SlaAlertCount = COUNT(*) FROM msdb.dbo.sysalerts
    WHERE enabled = 1
    AND (name LIKE '%latency%' OR name LIKE '%timeout%' OR name LIKE '%availability%' OR name LIKE '%performance%' OR name LIKE '%SLA%' OR description LIKE '%latency%' OR description LIKE '%timeout%');

    SET @Score = CASE
        WHEN @AlertCount = 0 OR @OperatorCount = 0 THEN 0
        WHEN @LinkedCount = 0 THEN 1
        WHEN @SlaAlertCount > 0 THEN 2
        ELSE 1
    END;
END
ELSE
BEGIN
    -- Azure SQL DB does not support SQL Agent alerts. Degrade gracefully.
    SET @Score = 1;
END;

-- NOTE: This script provides automated evidence. Full compliance requires human review.
-- Cap at 2 because SLA thresholds are business-defined and require human validation
IF @Score > 2 SET @Score = 2;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;