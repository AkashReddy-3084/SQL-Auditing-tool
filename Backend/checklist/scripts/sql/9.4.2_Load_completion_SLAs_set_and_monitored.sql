-- Checklist: Load completion SLAs set and monitored
-- Scope: SERVER
-- Scoring: 0=No load jobs or monitoring; 1=Load jobs exist but lack schedules or logging; 2=Load jobs have schedules and monitoring/logging artifacts exist; 3=Load jobs have schedules and explicit SLA threshold/alerting logic detected in monitoring objects.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT;
DECLARE @LoadJobCount INT = 0;
DECLARE @ScheduledJobCount INT = 0;
DECLARE @MonitorObjCount INT = 0;
DECLARE @SLALogicCount INT = 0;

SET @EngineEdition = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

-- Identify ETL/Load jobs (SQL Server / Azure SQL MI)
IF @EngineEdition <> 5
BEGIN
    SELECT @LoadJobCount = COUNT(*)
    FROM msdb.dbo.sysjobs j
    WHERE j.enabled = 1
      AND (j.name LIKE '%load%' OR j.name LIKE '%etl%' OR j.name LIKE '%import%' OR j.name LIKE '%sync%');

    SELECT @ScheduledJobCount = COUNT(DISTINCT j.job_id)
    FROM msdb.dbo.sysjobs j
    INNER JOIN msdb.dbo.sysjobschedules js ON j.job_id = js.job_id
    WHERE j.enabled = 1
      AND (j.name LIKE '%load%' OR j.name LIKE '%etl%' OR j.name LIKE '%import%' OR j.name LIKE '%sync%');
END
ELSE
BEGIN
    -- Azure SQL DB: Proxy using load/ETL procedures in current context
    SELECT @LoadJobCount = COUNT(*)
    FROM sys.procedures
    WHERE name LIKE '%load%' OR name LIKE '%etl%' OR name LIKE '%import%' OR name LIKE '%sync%';
    
    SET @ScheduledJobCount = @LoadJobCount;
END

-- Identify monitoring/logging tables or procedures in master/msdb
SELECT @MonitorObjCount = COUNT(*)
FROM sys.objects o
WHERE o.type IN ('U', 'P')
  AND (o.name LIKE '%log%' OR o.name LIKE '%monitor%' OR o.name LIKE '%sla%' OR o.name LIKE '%audit%')
  AND o.is_ms_shipped = 0;

-- Check for explicit SLA/threshold logic in monitoring objects
SELECT @SLALogicCount = COUNT(*)
FROM sys.sql_modules m
INNER JOIN sys.objects o ON m.object_id = o.object_id
WHERE o.type IN ('U', 'P')
  AND o.is_ms_shipped = 0
  AND (m.definition LIKE '%sla%' OR m.definition LIKE '%threshold%' OR m.definition LIKE '%duration%' OR m.definition LIKE '%alert%');

-- Determine Score
IF @LoadJobCount = 0 AND @MonitorObjCount = 0
    SET @Score = 0;
ELSE IF @LoadJobCount > 0 AND @ScheduledJobCount = 0 AND @MonitorObjCount = 0
    SET @Score = 1;
ELSE IF @ScheduledJobCount > 0 AND @MonitorObjCount > 0 AND @SLALogicCount = 0
    SET @Score = 2;
ELSE IF @ScheduledJobCount > 0 AND @MonitorObjCount > 0 AND @SLALogicCount > 0
    SET @Score = 3;
ELSE
    SET @Score = 1;

SET @DatabaseQueried = 'master';

-- Build Finding
SET @Finding = 'Load/ETL jobs found: ' + CAST(@LoadJobCount AS NVARCHAR(10)) + '; ';
SET @Finding = @Finding + 'Jobs with schedules: ' + CAST(@ScheduledJobCount AS NVARCHAR(10)) + '; ';
SET @Finding = @Finding + 'Monitoring/Logging objects: ' + CAST(@MonitorObjCount AS NVARCHAR(10)) + '; ';
SET @Finding = @Finding + 'Objects with SLA/threshold logic: ' + CAST(@SLALogicCount AS NVARCHAR(10));

IF @Score <= 1
    SET @Finding = @Finding + ' | No comprehensive SLA monitoring detected.';
ELSE IF @Score = 2
    SET @Finding = @Finding + ' | Monitoring exists but explicit SLA thresholds not verified.';
ELSE
    SET @Finding = @Finding + ' | SLA monitoring and threshold logic detected.';

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;