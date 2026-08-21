-- Checklist: Resource utilization trended over time
-- Scope: SERVER
-- Scoring: 0: No evidence of collection mechanism. 1: Single basic collection job or session found. 2: Structured collection job with multiple steps or multiple collection mechanisms found. 3: Comprehensive, multi-metric collection with clear historical retention strategy.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @JobCount INT = 0;
DECLARE @StepCount INT = 0;
DECLARE @JobList NVARCHAR(MAX) = '';
DECLARE @XeCount INT = 0;
DECLARE @XeList NVARCHAR(MAX) = '';

IF @EngineEdition <> 5
BEGIN
    SET @DatabaseQueried = 'master';
    
    SELECT @JobCount = COUNT(DISTINCT j.name),
           @StepCount = COUNT(*)
    FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.sysjobsteps s ON j.job_id = s.job_id
    WHERE j.enabled = 1
      AND (
        j.name LIKE '%performance%' OR j.name LIKE '%counter%' OR j.name LIKE '%resource%' OR j.name LIKE '%utilization%' OR j.name LIKE '%monitor%' OR j.name LIKE '%trend%' OR j.name LIKE '%health%' OR j.name LIKE '%metrics%'
        OR s.command LIKE '%dm_os%' OR s.command LIKE '%sp_whoisactive%' OR s.command LIKE '%query_store%' OR s.command LIKE '%performance_counter%' OR s.command LIKE '%sys.dm%'
      );

    SELECT @JobList = STRING_AGG(j.name, ', ')
    FROM (SELECT DISTINCT name FROM msdb.dbo.sysjobs j
          JOIN msdb.dbo.sysjobsteps s ON j.job_id = s.job_id
          WHERE j.enabled = 1
            AND (
              j.name LIKE '%performance%' OR j.name LIKE '%counter%' OR j.name LIKE '%resource%' OR j.name LIKE '%utilization%' OR j.name LIKE '%monitor%' OR j.name LIKE '%trend%' OR j.name LIKE '%health%' OR j.name LIKE '%metrics%'
              OR s.command LIKE '%dm_os%' OR s.command LIKE '%sp_whoisactive%' OR s.command LIKE '%query_store%' OR s.command LIKE '%performance_counter%' OR s.command LIKE '%sys.dm%'
            )
         ) AS J;
END
ELSE
BEGIN
    SET @DatabaseQueried = DB_NAME();
    
    SELECT @XeCount = COUNT(*)
    FROM sys.dm_xe_sessions s
    JOIN sys.dm_xe_session_targets t ON s.address = t.event_session_address
    WHERE s.name LIKE '%resource%' OR s.name LIKE '%performance%' OR s.name LIKE '%monitor%' OR s.name LIKE '%health%' OR s.name LIKE '%metrics%'
       OR t.target_name LIKE '%event_file%' OR t.target_name LIKE '%ring_buffer%';

    SELECT @XeList = STRING_AGG(s.name, ', ')
    FROM sys.dm_xe_sessions s
    JOIN sys.dm_xe_session_targets t ON s.address = t.event_session_address
    WHERE s.name LIKE '%resource%' OR s.name LIKE '%performance%' OR s.name LIKE '%monitor%' OR s.name LIKE '%health%' OR s.name LIKE '%metrics%'
       OR t.target_name LIKE '%event_file%' OR t.target_name LIKE '%ring_buffer%';
END

SET @Score = CASE
    WHEN @JobCount = 0 AND @XeCount = 0 THEN 0
    WHEN (@JobCount = 1 AND @StepCount = 1) OR @XeCount = 1 THEN 1
    WHEN (@JobCount >= 1 AND @StepCount >= 2) OR @XeCount >= 2 THEN 2
    WHEN @JobCount >= 2 OR @XeCount >= 3 THEN 3
    ELSE 0
END;

SET @Finding = CASE
    WHEN @JobCount = 0 AND @XeCount = 0 THEN 'No evidence of resource utilization collection or trending mechanism found.'
    WHEN @JobCount > 0 THEN 'Found ' + CAST(@JobCount AS NVARCHAR(10)) + ' SQL Agent job(s): ' + ISNULL(@JobList, 'None') + '. Steps: ' + CAST(@StepCount AS NVARCHAR(10)) + '.'
    ELSE 'Found ' + CAST(@XeCount AS NVARCHAR(10)) + ' Extended Event session(s): ' + ISNULL(@XeList, 'None') + '.'
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;