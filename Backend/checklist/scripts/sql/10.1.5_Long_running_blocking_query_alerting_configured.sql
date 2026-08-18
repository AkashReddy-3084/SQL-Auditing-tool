-- Checklist: Long-running/blocking query alerting configured
-- Scope: SERVER
-- Scoring: 0: No relevant alerts or monitoring jobs found. 1: Generic performance alerts exist but not specifically for blocking/long-running queries. 2: Monitoring configured (alert or job) but no notification operator linked, or relies on indirect metrics. 3: Explicit alerts or jobs configured for blocking/long-running queries with active notification operators.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @AlertNames NVARCHAR(MAX);
DECLARE @JobNames NVARCHAR(MAX);
DECLARE @OperatorNames NVARCHAR(MAX);

-- Check for SQL Agent Alerts related to blocking/long-running
SELECT @AlertNames = STRING_AGG(a.name, ', ') WITHIN GROUP (ORDER BY a.name)
FROM msdb.dbo.sysalerts a
WHERE a.message_id = 0
  AND (LOWER(a.name) LIKE '%block%' OR LOWER(a.name) LIKE '%long%run%' OR LOWER(a.name) LIKE '%timeout%' OR LOWER(a.name) LIKE '%deadlock%');

-- Check for SQL Agent Jobs/Steps monitoring blocking/long-running
SELECT @JobNames = STRING_AGG(j.name, ', ') WITHIN GROUP (ORDER BY j.name)
FROM msdb.dbo.sysjobs j
INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
WHERE LOWER(js.command) LIKE '%sys.dm_exec_requests%' 
   OR LOWER(js.command) LIKE '%sys.dm_os_waiting_tasks%' 
   OR LOWER(js.command) LIKE '%blocked%' 
   OR LOWER(js.command) LIKE '%long%run%';

-- Check for linked operators on relevant alerts
SELECT @OperatorNames = STRING_AGG(o.name, ', ') WITHIN GROUP (ORDER BY o.name)
FROM msdb.dbo.sysalerts a
INNER JOIN msdb.dbo.sysoperators o ON a.operator_id = o.id
WHERE a.message_id = 0
  AND (LOWER(a.name) LIKE '%block%' OR LOWER(a.name) LIKE '%long%run%' OR LOWER(a.name) LIKE '%timeout%' OR LOWER(a.name) LIKE '%deadlock%');

-- Determine Score
IF @AlertNames IS NOT NULL AND @OperatorNames IS NOT NULL
    SET @Score = 3;
ELSE IF @AlertNames IS NOT NULL OR @JobNames IS NOT NULL
    SET @Score = 2;
ELSE IF EXISTS (SELECT 1 FROM msdb.dbo.sysalerts WHERE message_id = 0)
    SET @Score = 1;
ELSE
    SET @Score = 0;

-- Build Finding
SET @Finding = CASE 
    WHEN @Score = 3 THEN 'Configured alerts: ' + @AlertNames + '; Notification operators: ' + @OperatorNames
    WHEN @Score = 2 THEN 'Monitoring configured but lacks operator linkage or uses indirect metrics. Alerts: ' + ISNULL(@AlertNames, 'None') + '; Jobs: ' + ISNULL(@JobNames, 'None')
    WHEN @Score = 1 THEN 'Generic alerts exist but not specifically for blocking/long-running queries.'
    ELSE 'No relevant alerts or monitoring jobs found.'
END;

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;