-- Checklist: ETL windows avoid contention with reporting/query workloads
-- Scope: SERVER
-- Scoring: 0=ETL runs during peak hours (08:00-18:00); 1=Partial separation or unclassifiable schedules; 2=ETL strictly off-peak; 3=Off-peak + Resource Governor workload isolation configured
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @EtlPeak INT = 0;
DECLARE @EtlOffPeak INT = 0;
DECLARE @RgIsolation BIT = 0;

-- Check for Resource Governor workload isolation (available on-prem & MI)
IF OBJECT_ID('sys.resource_governor_workload_groups') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.resource_governor_workload_groups WHERE name <> 'default')
        SET @RgIsolation = 1;
END

-- Collect job schedules if SQL Agent is available (On-prem / MI)
IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    SELECT
        @EtlPeak = COUNT(DISTINCT CASE WHEN (ISNULL(s.active_start_time, 0) / 10000) BETWEEN 8 AND 17 THEN j.job_id END),
        @EtlOffPeak = COUNT(DISTINCT CASE WHEN (ISNULL(s.active_start_time, 0) / 10000) < 8 OR (ISNULL(s.active_start_time, 0) / 10000) >= 18 THEN j.job_id END)
    FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.sysjobchedules js ON j.job_id = js.job_id
    JOIN msdb.dbo.sysschedules s ON js.schedule_id = s.schedule_id
    WHERE j.enabled = 1 AND s.enabled = 1
      AND (j.name LIKE '%ETL%' OR j.name LIKE '%Load%' OR j.name LIKE '%Ingest%' OR j.name LIKE '%Extract%');
END
ELSE
BEGIN
    -- Graceful degradation for Azure SQL DB (no native SQL Agent)
    SET @Score = 1;
END

-- Determine score based on schedule distribution
IF @Score IS NULL OR @Score = 0
BEGIN
    IF @EtlPeak > 0 AND @EtlOffPeak = 0
        SET @Score = 0;
    ELSE IF @EtlPeak > 0
        SET @Score = 1;
    ELSE IF @EtlOffPeak > 0 AND @RgIsolation = 1
        SET @Score = 3;
    ELSE IF @EtlOffPeak > 0
        SET @Score = 2;
    ELSE
        SET @Score = 1; -- No ETL jobs found / unclassifiable naming
END

-- NOTE: This script provides automated evidence. Full compliance requires human review.
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;