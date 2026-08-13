-- Checklist: Maintenance windows and patching approach defined (or Microsoft-managed for PaaS)
-- Scope: SERVER
-- Scoring: 0=No evidence, 1=Partial (unscheduled jobs), 2=Mostly (scheduled maintenance/patching jobs on-prem), 3=Pass (Microsoft-managed PaaS)
SET NOCOUNT ON;
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @JobCount INT = 0;
DECLARE @ScheduledJobCount INT = 0;

-- Check for PaaS (Azure SQL DB or Managed Instance)
IF @EngineEdition IN (5, 8)
BEGIN
    SET @Score = 3;
END
ELSE
BEGIN
    -- On-premises: look for maintenance/patching jobs
    IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
    BEGIN
        SELECT @JobCount = COUNT(*)
        FROM msdb.dbo.sysjobs j
        WHERE j.enabled = 1
          AND (j.name LIKE '%maintenance%' OR j.name LIKE '%patch%' OR j.name LIKE '%update%' OR j.name LIKE '%backup%');

        IF OBJECT_ID('msdb.dbo.sysjobschedules') IS NOT NULL
        BEGIN
            SELECT @ScheduledJobCount = COUNT(DISTINCT j.job_id)
            FROM msdb.dbo.sysjobs j
            INNER JOIN msdb.dbo.sysjobschedules js ON j.job_id = js.job_id
            WHERE j.enabled = 1
              AND (j.name LIKE '%maintenance%' OR j.name LIKE '%patch%' OR j.name LIKE '%update%' OR j.name LIKE '%backup%');
        END

        IF @ScheduledJobCount > 0
            SET @Score = 2;
        ELSE IF @JobCount > 0
            SET @Score = 1;
        ELSE
            SET @Score = 0;
    END
    ELSE
    BEGIN
        SET @Score = 0;
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;
-- NOTE: This script provides automated evidence. Full compliance requires human review.