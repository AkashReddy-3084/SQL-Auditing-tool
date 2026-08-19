-- Checklist: Fragmentation-based maintenance (rebuild/reorganize) automated
-- Scope: SERVER
-- Scoring: 3 = Job found with index maintenance keywords; 2 = Job found but keywords vague; 1 = Job exists but no maintenance keywords; 0 = No maintenance jobs found

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No automated index maintenance jobs found';

DECLARE @JobCount INT = 0;
DECLARE @StrongMatch INT = 0;
DECLARE @WeakMatch INT = 0;

-- Search for jobs that likely perform index maintenance
-- We look for keywords in the job name or the command text of the job steps
SELECT 
    @JobCount = COUNT(DISTINCT j.job_id),
    @StrongMatch = COUNT(DISTINCT CASE 
        WHEN j.name LIKE '%index%' OR j.name LIKE '%rebuild%' OR j.name LIKE '%reorganize%' 
        OR s.command LIKE '%ALTER INDEX%' OR s.command LIKE '%index_physical_stats%' 
        THEN j.job_id END),
    @WeakMatch = COUNT(DISTINCT CASE 
        WHEN j.name LIKE '%maintenance%' OR s.command LIKE '%maintenance%' 
        THEN j.job_id END)
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps s ON j.job_id = s.job_id
WHERE (j.name LIKE '%index%' OR j.name LIKE '%rebuild%' OR j.name LIKE '%reorganize%' OR j.name LIKE '%maintenance%')
   OR (s.command LIKE '%ALTER INDEX%' OR s.command LIKE '%index_physical_stats%' OR s.command LIKE '%maintenance%');

IF @StrongMatch > 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'Found ' + CAST(@StrongMatch AS NVARCHAR(10)) + ' job(s) with explicit index maintenance commands or naming.';
END
ELSE IF @WeakMatch > 0
BEGIN
    SET @Score = 2;
    SET @Finding = 'Found ' + CAST(@WeakMatch AS NVARCHAR(10)) + ' job(s) with general maintenance naming; specific index logic not explicitly confirmed.';
END
ELSE IF @JobCount > 0
BEGIN
    SET @Score = 1;
    SET @Finding = 'Jobs found but no clear index maintenance keywords identified in names or steps.';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = 'No SQL Agent jobs found matching index maintenance patterns.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;