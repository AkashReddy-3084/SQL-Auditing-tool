-- Checklist: ETL/job run history captured and retained
-- Scope: SERVER
-- Scoring: 3=History captured & retained, 2=History captured but no jobs, 1=Jobs exist but no history, 0=No jobs/history or platform unsupported

SET NOCOUNT ON;

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @JobCount INT = 0;
DECLARE @HistoryCount INT = 0;
DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

IF @EngineEdition = 5
BEGIN
    SET @Score = 0;
    SET @Finding = 'SQL Agent not available in Azure SQL Database. History capture/retention not applicable.';
END
ELSE
BEGIN
    IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
        SELECT @JobCount = COUNT(*) FROM msdb.dbo.sysjobs;
        
    IF OBJECT_ID('msdb.dbo.sysjobhistory') IS NOT NULL
        SELECT @HistoryCount = COUNT(*) 
        FROM msdb.dbo.sysjobhistory 
        WHERE run_date >= CAST(CONVERT(VARCHAR(8), DATEADD(DAY, -30, GETDATE()), 112) AS INT);

    IF @HistoryCount > 0 AND @JobCount > 0
        SET @Score = 3;
    ELSE IF @HistoryCount > 0 AND @JobCount = 0
        SET @Score = 2;
    ELSE IF @HistoryCount = 0 AND @JobCount > 0
        SET @Score = 1;
    ELSE
        SET @Score = 0;

    SET @Finding = 'Jobs configured: ' + CAST(@JobCount AS NVARCHAR(10)) + ', History records (last 30 days): ' + CAST(@HistoryCount AS NVARCHAR(10));
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;