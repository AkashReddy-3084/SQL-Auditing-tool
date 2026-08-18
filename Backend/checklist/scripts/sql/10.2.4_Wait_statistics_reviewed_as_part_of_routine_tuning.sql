-- Checklist: Wait statistics reviewed as part of routine tuning
-- Scope: SERVER
-- Scoring: 0: Wait stats unavailable/empty. 1: Wait stats populated, no proxy evidence of review. 2: Wait stats populated, proxy evidence of routine review/capture found. (Note: Full compliance requires human review.)
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @WaitStatsTotal BIGINT;
DECLARE @JobCount INT = 0;

-- Check wait statistics availability and accumulation
SELECT @WaitStatsTotal = SUM(wait_time_ms) FROM sys.dm_os_wait_stats;

-- Check for proxy evidence of routine tuning/review (SQL Agent jobs)
IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    SELECT @JobCount = COUNT(*) 
    FROM msdb.dbo.sysjobs 
    WHERE name LIKE '%wait%' OR name LIKE '%tuning%' OR name LIKE '%performance%';
END

SET @Score = 0;
SET @Finding = '';

IF @WaitStatsTotal IS NULL OR @WaitStatsTotal = 0
BEGIN
    SET @Score = 0;
    SET @Finding = 'Wait statistics are unavailable or empty. No evidence of routine tuning.'
END
ELSE IF @JobCount = 0
BEGIN
    SET @Score = 1;
    SET @Finding = 'Wait statistics are populated (Total wait time: ' + CAST(@WaitStatsTotal AS NVARCHAR) + ' ms), but no automated capture/review jobs detected.'
END
ELSE
BEGIN
    SET @Score = 2;
    SET @Finding = 'Wait statistics are populated (Total wait time: ' + CAST(@WaitStatsTotal AS NVARCHAR) + ' ms) and ' + CAST(@JobCount AS NVARCHAR) + ' potential tuning/review job(s) detected.'
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;