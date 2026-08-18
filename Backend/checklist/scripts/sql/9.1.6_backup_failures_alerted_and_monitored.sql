-- Checklist: Backup failures alerted and monitored
-- Scope: SERVER
-- Scoring: 0: No backup jobs or zero notifications/alerts. 1: <50% jobs notified, no alerts. 2: >=50% jobs notified or alerts exist. 3: All jobs notified.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

SET NOCOUNT ON;

DECLARE @TotalBackupJobs INT;
DECLARE @NotifiedJobs INT;
DECLARE @AlertCount INT;
DECLARE @NonNotifiedJobs NVARCHAR(MAX);

SELECT @TotalBackupJobs = COUNT(*),
       @NotifiedJobs = SUM(CASE WHEN notify_level_email >= 2 OR notify_level_page >= 2 OR notify_level_netsend >= 2 THEN 1 ELSE 0 END)
FROM msdb.dbo.sysjobs
WHERE name LIKE '%backup%';

SELECT @AlertCount = COUNT(*)
FROM msdb.dbo.sysalerts
WHERE description LIKE '%backup%' OR message_id BETWEEN 926 AND 999;

SELECT @NonNotifiedJobs = STRING_AGG(name, ', ')
FROM msdb.dbo.sysjobs
WHERE name LIKE '%backup%'
  AND notify_level_email < 2 AND notify_level_page < 2 AND notify_level_netsend < 2;

IF @TotalBackupJobs = 0
    SET @Score = 0;
ELSE IF @NotifiedJobs = @TotalBackupJobs
    SET @Score = 3;
ELSE IF @NotifiedJobs * 2 >= @TotalBackupJobs OR @AlertCount > 0
    SET @Score = 2;
ELSE IF @NotifiedJobs > 0
    SET @Score = 1;
ELSE
    SET @Score = 0;

IF @TotalBackupJobs = 0
    SET @Finding = 'No backup jobs found in SQL Server Agent.';
ELSE IF @Score = 3
    SET @Finding = 'All ' + CAST(@TotalBackupJobs AS NVARCHAR) + ' backup jobs have failure notifications configured.' + CASE WHEN @AlertCount > 0 THEN ' ' + CAST(@AlertCount AS NVARCHAR) + ' backup failure alert(s) also configured.' ELSE '' END;
ELSE IF @Score = 2
    SET @Finding = CAST(@NotifiedJobs AS NVARCHAR) + ' of ' + CAST(@TotalBackupJobs AS NVARCHAR) + ' backup jobs have failure notifications configured.' + CASE WHEN @AlertCount > 0 THEN ' ' + CAST(@AlertCount AS NVARCHAR) + ' backup failure alert(s) configured.' ELSE '' END + CASE WHEN @NonNotifiedJobs IS NOT NULL THEN ' Jobs without notifications: ' + @NonNotifiedJobs ELSE '' END;
ELSE IF @Score = 1
    SET @Finding = CAST(@NotifiedJobs AS NVARCHAR) + ' of ' + CAST(@TotalBackupJobs AS NVARCHAR) + ' backup jobs have failure notifications configured. No backup failure alerts found. Jobs without notifications: ' + ISNULL(@NonNotifiedJobs, 'None');
ELSE
    SET @Finding = 'Backup jobs found but none have failure notifications or alerts configured. Jobs: ' + ISNULL(@NonNotifiedJobs, 'None');

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;