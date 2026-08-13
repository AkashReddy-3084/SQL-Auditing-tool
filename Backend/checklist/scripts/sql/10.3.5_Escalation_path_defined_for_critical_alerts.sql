-- Checklist: Escalation path defined for critical alerts
-- Scope: SERVER
-- Scoring: 0=No critical alerts or none have operators; 1=Some critical alerts have operators (<50%); 2=Most critical alerts have operators (>=50%); 3=All critical alerts have operators assigned
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

IF OBJECT_ID('msdb.dbo.sysalerts') IS NOT NULL
BEGIN
    DECLARE @TotalCritical INT = 0;
    DECLARE @AssignedCritical INT = 0;

    SELECT @TotalCritical = COUNT(*)
    FROM msdb.dbo.sysalerts
    WHERE severity >= 19 OR name LIKE '%critical%' OR name LIKE '%error%';

    SELECT @AssignedCritical = COUNT(DISTINCT a.id)
    FROM msdb.dbo.sysalerts a
    INNER JOIN msdb.dbo.sysnotifications n ON a.id = n.alert_id
    WHERE (a.severity >= 19 OR a.name LIKE '%critical%' OR a.name LIKE '%error%');

    IF @TotalCritical = 0
        SET @Score = 0;
    ELSE IF @AssignedCritical = @TotalCritical
        SET @Score = 3;
    ELSE IF CAST(@AssignedCritical AS FLOAT) / @TotalCritical >= 0.5
        SET @Score = 2;
    ELSE IF @AssignedCritical > 0
        SET @Score = 1;
    ELSE
        SET @Score = 0;
END
ELSE
BEGIN
    SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;