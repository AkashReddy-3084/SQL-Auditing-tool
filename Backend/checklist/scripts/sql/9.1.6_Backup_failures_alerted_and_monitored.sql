USE master;
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @AgentEnabled INT = 0;
DECLARE @AlertCount INT = 0;
DECLARE @OperatorCount INT = 0;
DECLARE @NotificationCount INT = 0;
DECLARE @RecentBackupCount INT = 0;

-- Check SQL Agent status
SELECT @AgentEnabled = ISNULL(value_in_use, 0) FROM sys.configurations WHERE name = 'Agent XPs';

-- Check for backup-related alerts, operators, and notification routing
IF OBJECT_ID('msdb.dbo.sysalerts') IS NOT NULL
BEGIN
    SELECT @AlertCount = COUNT(*) FROM msdb.dbo.sysalerts 
    WHERE name LIKE '%backup%' OR message_id BETWEEN 3013 AND 3099;
    
    SELECT @OperatorCount = COUNT(*) FROM msdb.dbo.sysoperators WHERE enabled = 1;
    
    SELECT @NotificationCount = COUNT(*) FROM msdb.dbo.sysnotifications 
    WHERE alert_id IN (
        SELECT alert_id FROM msdb.dbo.sysalerts 
        WHERE name LIKE '%backup%' OR message_id BETWEEN 3013 AND 3099
    );
END
ELSE
BEGIN
    -- Azure SQL DB lacks msdb/Agent; backup alerting is handled via Azure Monitor/Action Groups
    -- Degrade to partial evidence score
    SET @Score = 1;
END

-- Check recent backup activity (last 7 days) to verify monitoring is active
IF OBJECT_ID('msdb.dbo.backupset') IS NOT NULL
BEGIN
    SELECT @RecentBackupCount = COUNT(*) FROM msdb.dbo.backupset 
    WHERE backup_start_date >= DATEADD(day, -7, GETDATE());
END

-- Scoring logic (only apply if not already set for Azure fallback)
IF @Score = 0
BEGIN
    IF @AgentEnabled = 0 OR @AlertCount = 0
        SET @Score = 0;
    ELSE IF @OperatorCount = 0 OR @NotificationCount = 0
        SET @Score = 1;
    ELSE IF @RecentBackupCount = 0
        SET @Score = 2;
    ELSE
        SET @Score = 3;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;