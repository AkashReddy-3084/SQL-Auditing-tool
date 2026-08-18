-- Checklist: SLA breach triggers alerts
-- Scope: SERVER
-- Scoring: 0=No alerts found; 1=Alerts found but disabled OR platform lacks SQL Agent; 2=Alerts enabled but no notifications configured; 3=Alerts enabled with notifications configured.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

IF @EngineEdition <> 5
BEGIN
    DECLARE @AlertCount INT = 0;
    DECLARE @EnabledCount INT = 0;
    DECLARE @NotifiedCount INT = 0;
    DECLARE @AlertNames NVARCHAR(MAX) = '';

    SELECT @AlertCount = COUNT(*)
    FROM msdb.dbo.sysalerts
    WHERE name LIKE '%SLA%' OR name LIKE '%breach%' OR name LIKE '%threshold%' OR name LIKE '%violation%'
       OR description LIKE '%SLA%' OR description LIKE '%breach%' OR description LIKE '%threshold%' OR description LIKE '%violation%';

    IF @AlertCount > 0
    BEGIN
        SELECT @EnabledCount = COUNT(*)
        FROM msdb.dbo.sysalerts
        WHERE (name LIKE '%SLA%' OR name LIKE '%breach%' OR name LIKE '%threshold%' OR name LIKE '%violation%'
           OR description LIKE '%SLA%' OR description LIKE '%breach%' OR description LIKE '%threshold%' OR description LIKE '%violation%')
          AND enabled = 1;

        SELECT @NotifiedCount = COUNT(*)
        FROM msdb.dbo.sysalerts
        WHERE (name LIKE '%SLA%' OR name LIKE '%breach%' OR name LIKE '%threshold%' OR name LIKE '%violation%'
           OR description LIKE '%SLA%' OR description LIKE '%breach%' OR description LIKE '%threshold%' OR description LIKE '%violation%')
          AND enabled = 1
          AND (has_notification_email = 1 OR has_notification_page = 1 OR has_notification_netsend = 1);

        SELECT @AlertNames = STRING_AGG(name, ', ')
        FROM msdb.dbo.sysalerts
        WHERE (name LIKE '%SLA%' OR name LIKE '%breach%' OR name LIKE '%threshold%' OR name LIKE '%violation%'
           OR description LIKE '%SLA%' OR description LIKE '%breach%' OR description LIKE '%threshold%' OR description LIKE '%violation%');
    END

    IF @NotifiedCount > 0
        SET @Score = 3;
    ELSE IF @EnabledCount > 0
        SET @Score = 2;
    ELSE IF @AlertCount > 0
        SET @Score = 1;
    ELSE
        SET @Score = 0;

    IF @Score = 3
        SET @Finding = 'SLA breach alerts configured and enabled with notifications: ' + ISNULL(@AlertNames, 'None');
    ELSE IF @Score = 2
        SET @Finding = 'SLA breach alerts configured and enabled but no notifications assigned: ' + ISNULL(@AlertNames, 'None');
    ELSE IF @Score = 1
        SET @Finding = 'SLA breach alerts found but disabled: ' + ISNULL(@AlertNames, 'None');
    ELSE
        SET @Finding = 'No alerts configured for SLA breaches or thresholds.';
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = 'SQL Server Agent not available in Azure SQL Database. Manual review of monitoring/alerting configuration required.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SET @DatabaseQueried = 'master';

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;