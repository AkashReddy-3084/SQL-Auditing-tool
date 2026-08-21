-- Checklist: ETL windows avoid contention with reporting/query workloads
-- Scope: SERVER
-- Scoring: 0: All ETL jobs run during business hours (08:00-18:00) or no schedules found. 1: Some ETL jobs run during business hours, but majority are off-peak. 2: Most ETL jobs run off-peak, minor overlaps or missing schedules. 3: All ETL jobs run strictly off-peak (before 08:00 or after 18:00) or on weekends.

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database does not support SQL Agent. ETL scheduling is managed externally.
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database does not support SQL Agent. ETL scheduling is managed externally (e.g., Data Factory). Automated verification not possible.';
    SET @DatabaseQueried = 'master';
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
    
    SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
    RETURN;
END

-- SQL Server / Azure SQL MI evaluation
DECLARE @TotalETL INT = 0;
DECLARE @PeakETL INT = 0;
DECLARE @PeakJobs NVARCHAR(MAX) = '';

SELECT 
    j.name AS JobName,
    s.active_start_time
INTO #ETLSchedules
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobschedules js ON j.job_id = js.job_id
JOIN msdb.dbo.sysschedules s ON js.schedule_id = s.schedule_id
WHERE j.enabled = 1
  AND (j.name LIKE '%ETL%' 
    OR j.name LIKE '%Load%' 
    OR j.name LIKE '%Extract%' 
    OR j.name LIKE '%Transform%' 
    OR j.name LIKE '%Staging%' 
    OR j.name LIKE '%DW%' 
    OR j.name LIKE '%DataWarehouse%');

SET @TotalETL = (SELECT COUNT(*) FROM #ETLSchedules);

-- Identify jobs running during business hours (08:00 - 18:00)
-- active_start_time is stored as INT in HHMMSS format
SELECT @PeakETL = COUNT(*),
       @PeakJobs = STRING_AGG(JobName, ', ')
FROM #ETLSchedules
WHERE active_start_time BETWEEN 80000 AND 180000;

IF @TotalETL = 0
BEGIN
    SET @Score = 0;
    SET @Finding = 'No ETL jobs with schedules found. Cannot verify workload separation.';
END
ELSE
BEGIN
    DECLARE @OffPeakPct FLOAT = CAST(@TotalETL - @PeakETL AS FLOAT) / @TotalETL * 100;
    
    IF @OffPeakPct >= 100
        SET @Score = 3;
    ELSE IF @OffPeakPct >= 80
        SET @Score = 2;
    ELSE IF @OffPeakPct > 0
        SET @Score = 1;
    ELSE
        SET @Score = 0;

    IF @PeakETL > 0
        SET @Finding = CAST(@PeakETL AS NVARCHAR) + ' of ' + CAST(@TotalETL AS NVARCHAR) + ' ETL jobs scheduled during business hours (08:00-18:00): ' + @PeakJobs;
    ELSE
        SET @Finding = 'All ' + CAST(@TotalETL AS NVARCHAR) + ' ETL jobs are scheduled outside business hours. No contention risk detected.';
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;

DROP TABLE #ETLSchedules;