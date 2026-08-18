-- Checklist: Maintenance windows and patching approach defined (or Microsoft-managed for PaaS)
-- Scope: SERVER
-- Scoring: 3: PaaS (Microsoft-managed). 2: On-prem with >=1 scheduled maintenance/patching job. 1: On-prem with no scheduled jobs. 0: On-prem with no scheduled jobs and server offline.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT;
DECLARE @JobCount INT;
DECLARE @JobNames NVARCHAR(MAX);

SET @EngineEdition = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
SET @DatabaseQueried = 'master';

IF @EngineEdition IN (5, 8)
BEGIN
    SET @Score = 3;
    SET @Finding = 'PaaS environment detected (EngineEdition: ' + CAST(@EngineEdition AS NVARCHAR(10)) + '). Patching and maintenance are Microsoft-managed.';
END
ELSE
BEGIN
    SELECT @JobCount = COUNT(1),
           @JobNames = STRING_AGG(name, ', ') WITHIN GROUP (ORDER BY name)
    FROM (
        SELECT DISTINCT j.name
        FROM msdb.dbo.sysjobs j
        INNER JOIN msdb.dbo.sysjobschedules js ON j.job_id = js.job_id
        WHERE j.enabled = 1
          AND (j.name LIKE '%Maintenance%' OR j.name LIKE '%Patch%' OR j.name LIKE '%Update%' 
               OR j.name LIKE '%Backup%' OR j.name LIKE '%Index%' OR j.name LIKE '%Statistics%' 
               OR j.name LIKE '%DBCC%')
    ) AS Jobs;

    IF ISNULL(@JobCount, 0) >= 1
    BEGIN
        SET @Score = 2;
        SET @Finding = 'On-prem environment. ' + CAST(@JobCount AS NVARCHAR(10)) + ' scheduled maintenance/patching job(s) found: ' + ISNULL(@JobNames, 'None');
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Finding = 'On-prem environment. No scheduled maintenance or patching jobs found.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;