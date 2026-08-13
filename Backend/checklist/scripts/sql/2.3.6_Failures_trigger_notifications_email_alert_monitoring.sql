-- Checklist: Failures trigger notifications (email/alert/monitoring)
-- Scope: SERVER
-- Scoring: 0=No notification infrastructure configured; 1=Partial (DB Mail enabled OR operators exist); 2=Good (Alerts OR job failure notifications configured); 3=Fully configured (DB Mail, operators, alerts, and job failure notifications all present)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbMailEnabled INT = 0;
DECLARE @OperatorCount INT = 0;
DECLARE @AlertCount INT = 0;
DECLARE @JobNotifyCount INT = 0;

-- Check Database Mail XPs
SELECT @DbMailEnabled = value_in_use FROM sys.configurations WHERE name = 'Database Mail XPs';

-- Check Operators
SELECT @OperatorCount = COUNT(*) FROM msdb.dbo.sysoperators;

-- Check Alerts
SELECT @AlertCount = COUNT(*) FROM msdb.dbo.sysalerts;

-- Check Jobs with failure notification
SELECT @JobNotifyCount = COUNT(*) FROM msdb.dbo.sysjobs WHERE notify_level_email IN (2, 3);

-- Calculate Score based on component presence
SET @Score = 0;
IF @DbMailEnabled = 1 SET @Score = @Score + 1;
IF @OperatorCount > 0 SET @Score = @Score + 1;
IF @AlertCount > 0 SET @Score = @Score + 1;
IF @JobNotifyCount > 0 SET @Score = @Score + 1;

-- Map to 0-3 scale
SET @Score = CASE 
    WHEN @Score = 0 THEN 0
    WHEN @Score = 1 THEN 1
    WHEN @Score = 2 THEN 2
    WHEN @Score >= 3 THEN 3
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score;