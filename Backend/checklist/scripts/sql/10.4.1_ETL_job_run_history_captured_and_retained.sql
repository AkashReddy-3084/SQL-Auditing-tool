-- Checklist: ETL/job run history captured and retained
-- Scope: SERVER
-- Scoring: 0=Retention disabled or no history; 1=Low retention (<1000 rows) or stale history (>30 days); 2=Adequate retention (>=1000 rows) with history; 3=Optimal retention (>=10000 rows) with recent history (<7 days)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @MaxRows INT = 0;
DECLARE @HistCount INT = 0;
DECLARE @MaxRunDate INT = 0;
DECLARE @Threshold30Days INT = CONVERT(INT, CONVERT(VARCHAR(8), DATEADD(DAY, -30, GETDATE()), 112));
DECLARE @Threshold7Days INT = CONVERT(INT, CONVERT(VARCHAR(8), DATEADD(DAY, -7, GETDATE()), 112));

-- Check retention configuration
SELECT @MaxRows = ISNULL(value_in_use, 0) FROM sys.configurations WHERE name = 'job history max rows';

-- Check actual history records
SELECT @HistCount = COUNT(*), @MaxRunDate = ISNULL(MAX(run_date), 0) FROM msdb.dbo.sysjobhistory;

-- Assign score based on retention config and history freshness
-- Using CASE to prevent IF/ELSE IF ordering issues and ensure correct priority evaluation
SET @Score = CASE
    WHEN @MaxRows = 0 OR @HistCount = 0 THEN 0
    WHEN @MaxRows >= 10000 AND @MaxRunDate >= @Threshold7Days THEN 3
    WHEN @MaxRows >= 1000 AND @MaxRunDate >= @Threshold30Days THEN 2
    ELSE 1
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;