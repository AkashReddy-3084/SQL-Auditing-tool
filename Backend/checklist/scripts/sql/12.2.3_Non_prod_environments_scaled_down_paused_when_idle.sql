-- Checklist: Non-prod environments scaled down / paused when idle
-- Scope: SERVER
-- Scoring: 3=Idle (0 connections/requests), 2=Low activity (1-3 connections), 1=Moderate activity (4-10 connections), 0=High activity (>10 connections). Proxy evidence noted.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @ConnCount INT;
DECLARE @ReqCount INT;

SELECT @ConnCount = COUNT(*) FROM sys.dm_exec_connections WHERE session_id > 50;
SELECT @ReqCount = COUNT(*) FROM sys.dm_exec_requests WHERE session_id > 50;

SET @Score = CASE
    WHEN @ConnCount = 0 AND @ReqCount = 0 THEN 3
    WHEN @ConnCount <= 3 AND @ReqCount = 0 THEN 2
    WHEN @ConnCount <= 10 THEN 1
    ELSE 0
END;

SET @DatabaseQueried = 'master';
SET @Finding = 'Active connections: ' + CAST(@ConnCount AS NVARCHAR(10)) + ', Active requests: ' + CAST(@ReqCount AS NVARCHAR(10)) + '. ' +
    CASE WHEN @Score >= 2 THEN 'Environment appears idle. ' ELSE 'Environment is active. ' END +
    'NOTE: This script provides automated evidence. Full compliance requires human review.';

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;