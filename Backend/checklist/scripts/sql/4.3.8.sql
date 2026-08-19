-- Checklist: Index maintenance (rebuild/reorganize) scheduled based on fragmentation
-- Scope: SERVER
-- Scoring: 3 = Job found with rebuild/reorganize logic; 2 = Job found but logic is vague; 1 = Job exists but no maintenance keywords; 0 = No maintenance jobs found

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No index maintenance jobs found';

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database: Index maintenance is typically handled by the platform or via Elastic Jobs/Automation; server-level Agent not applicable.';
END
ELSE
BEGIN
    DECLARE @JobCount INT = 0;
    DECLARE @MaintenanceJobCount INT = 0;
    DECLARE @JobNames NVARCHAR(MAX) = '';

    -- Use a temp table to avoid aggregation errors with STRING_AGG
    SELECT 
        j.name AS JobName,
        s.step_command AS Command
    INTO #Jobs
    FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.sysjobsteps s ON j.job_id = s.job_id
    WHERE (j.name LIKE '%index%' OR j.name LIKE '%maint%' OR s.step_command LIKE '%REBUILD%' OR s.step_command LIKE '%REORGANIZE%');

    SELECT @JobCount = COUNT(*) FROM #Jobs;

    IF @JobCount > 0
    BEGIN
        SELECT @MaintenanceJobCount = COUNT(*) 
        FROM #Jobs 
        WHERE (Command LIKE '%REBUILD%' OR Command LIKE '%REORGANIZE%');

        SELECT @JobNames = STRING_AGG(CAST(JobName AS NVARCHAR(MAX)), ', ') FROM (SELECT DISTINCT JobName FROM #Jobs) AS DistinctJobs;

        IF @MaintenanceJobCount > 0
        BEGIN
            SET @Score = 3;
            SET @Finding = 'Maintenance jobs found with rebuild/reorganize logic: ' + @JobNames;
        END
        ELSE
        BEGIN
            -- If jobs were found based on name but no rebuild/reorganize commands, it's either vague (2) or no keywords (1)
            -- We check if the name suggests maintenance but the command doesn't
            IF EXISTS (SELECT 1 FROM #Jobs WHERE JobName LIKE '%index%' OR JobName LIKE '%maint%')
            BEGIN
                SET @Score = 1;
                SET @Finding = 'Jobs found but no explicit REBUILD/REORGANIZE commands detected: ' + @JobNames;
            END
            ELSE
            BEGIN
                SET @Score = 2;
                SET @Finding = 'Jobs found but maintenance logic is vague: ' + @JobNames;
            END
        END
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No SQL Agent jobs found matching index maintenance patterns';
    END
    DROP TABLE #Jobs;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;