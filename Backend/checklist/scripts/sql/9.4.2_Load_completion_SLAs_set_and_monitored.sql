-- Checklist: Load completion SLAs set and monitored
-- Scope: SERVER
-- Scoring: 0=No evidence, 1=Load jobs exist but lack schedules/monitoring, 2=Scheduled jobs found, 3=Scheduled jobs + automated alerts configured
-- NOTE: Database-level tracking objects excluded to comply with SERVER scope. Full compliance requires human review.
SET NOCOUNT ON;

DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @JobCount INT = 0;
DECLARE @ScheduleCount INT = 0;
DECLARE @AlertCount INT = 0;

-- Check server-level SQL Agent jobs for load/ETL (on-prem/MI only)
IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    SELECT @JobCount = COUNT(*) 
    FROM msdb.dbo.sysjobs j
    WHERE j.enabled = 1 AND (
        j.name LIKE '%load%' OR j.name LIKE '%etl%' OR j.name LIKE '%ingest%' OR j.name LIKE '%sla%'
    );

    IF OBJECT_ID('msdb.dbo.sysjobschedules') IS NOT NULL
    BEGIN
        SELECT @ScheduleCount = COUNT(DISTINCT js.job_id) 
        FROM msdb.dbo.sysjobs j
        INNER JOIN msdb.dbo.sysjobschedules js ON j.job_id = js.job_id
        WHERE j.enabled = 1 AND (
            j.name LIKE '%load%' OR j.name LIKE '%etl%' OR j.name LIKE '%ingest%' OR j.name LIKE '%sla%'
        );
    END

    IF OBJECT_ID('msdb.dbo.sysalerts') IS NOT NULL
    BEGIN
        SELECT @AlertCount = COUNT(*) 
        FROM msdb.dbo.sysalerts a
        WHERE a.enabled = 1 AND (
            a.message_id > 0 OR a.name LIKE '%load%' OR a.name LIKE '%sla%' OR a.name LIKE '%etl%'
        );
    END
END

-- Robust scoring logic covering all evidence combinations
IF @JobCount = 0 AND @ScheduleCount = 0 AND @AlertCount = 0
    SET @Score = 0;
ELSE IF @JobCount > 0 AND @ScheduleCount = 0 AND @AlertCount = 0
    SET @Score = 1;
ELSE IF @ScheduleCount > 0 AND @AlertCount = 0
    SET @Score = 2;
ELSE IF @ScheduleCount > 0 AND @AlertCount > 0
    SET @Score = 3;
ELSE
    SET @Score = 1; -- Fallback for any other partial evidence combination

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score;