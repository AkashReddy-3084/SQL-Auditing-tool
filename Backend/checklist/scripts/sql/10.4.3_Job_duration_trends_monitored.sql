-- Checklist: Job duration trends monitored
-- Scope: SERVER
-- Scoring: 0=No evidence, 1=History only, 2=History+operators, 3=History+operators+explicit trend tracking
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @HistoryCount INT = 0;
DECLARE @OperatorCount INT = 0;
DECLARE @TrendArtifactCount INT = 0;

-- 1. Check SQL Agent job history for recent runs (last 30 days)
IF OBJECT_ID('msdb.dbo.sysjobhistory') IS NOT NULL
BEGIN
    SELECT @HistoryCount = COUNT(*) 
    FROM msdb.dbo.sysjobhistory 
    WHERE run_date >= CONVERT(VARCHAR(8), DATEADD(DAY, -30, GETDATE()), 112);
END

-- 2. Check configured operators for job notifications
IF OBJECT_ID('msdb.dbo.sysoperators') IS NOT NULL
BEGIN
    SELECT @OperatorCount = COUNT(*) FROM msdb.dbo.sysoperators;
END

-- 3. Check for explicit trend tracking tables or duration-based alerts
IF OBJECT_ID('msdb.dbo.sysalerts') IS NOT NULL
BEGIN
    SELECT @TrendArtifactCount = COUNT(*) 
    FROM msdb.dbo.sysalerts 
    WHERE message_id = 0 AND (name LIKE '%duration%' OR name LIKE '%runtime%' OR name LIKE '%trend%');
END

-- Also scan msdb for custom monitoring tables
SELECT @TrendArtifactCount = @TrendArtifactCount + COUNT(*)
FROM msdb.sys.tables
WHERE name LIKE '%job%history%' OR name LIKE '%etl%monitor%' OR name LIKE '%run%time%' OR name LIKE '%duration%track%';

-- Calculate score based on evidence accumulation
IF @HistoryCount > 0 SET @Score = @Score + 1;
IF @OperatorCount > 0 SET @Score = @Score + 1;
IF @TrendArtifactCount > 0 SET @Score = @Score + 1;

-- Cap at 3
IF @Score > 3 SET @Score = 3;

-- NOTE: This script provides automated evidence. Full compliance requires human review.
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;