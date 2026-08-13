-- Checklist: Consistency checks (DBCC CHECKDB) scheduled and monitored (SQL Server/MI)
-- Scope: SERVER
-- Scoring: 0=No jobs found, 1=Job found but disabled/unscheduled, 2=Enabled & scheduled but no recent success, 3=Enabled, scheduled & recently successful
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @JobCount INT = 0;
DECLARE @EnabledCount INT = 0;
DECLARE @ScheduledCount INT = 0;
DECLARE @RecentSuccessCount INT = 0;

IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    SELECT @JobCount = COUNT(*)
    FROM msdb.dbo.sysjobs j
    INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
    WHERE js.command LIKE '%DBCC CHECKDB%';

    IF @JobCount > 0
    BEGIN
        SELECT @EnabledCount = COUNT(*)
        FROM msdb.dbo.sysjobs j
        INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
        WHERE js.command LIKE '%DBCC CHECKDB%' AND j.enabled = 1;

        SELECT @ScheduledCount = COUNT(DISTINCT j.job_id)
        FROM msdb.dbo.sysjobs j
        INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
        INNER JOIN msdb.dbo.sysjobschedules jsch ON j.job_id = jsch.job_id
        WHERE js.command LIKE '%DBCC CHECKDB%' AND j.enabled = 1 AND jsch.enabled = 1;

        SELECT @RecentSuccessCount = COUNT(DISTINCT j.job_id)
        FROM msdb.dbo.sysjobs j
        INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
        INNER JOIN msdb.dbo.sysjobhistory jh ON j.job_id = jh.job_id
        WHERE js.command LIKE '%DBCC CHECKDB%' 
          AND j.enabled = 1
          AND jh.step_id = 0
          AND jh.run_status = 0
          AND jh.run_date >= CONVERT(INT, CONVERT(VARCHAR(8), GETDATE() - 7, 112));
    END
END

IF @JobCount = 0 SET @Score = 0;
ELSE IF @EnabledCount = 0 OR @ScheduledCount = 0 SET @Score = 1;
ELSE IF @RecentSuccessCount = 0 SET @Score = 2;
ELSE SET @Score = 3;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;