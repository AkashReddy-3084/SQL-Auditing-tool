-- Checklist: Job duration trends monitored
-- Scope: SERVER
-- Scoring: 0: No job history or retention < 7 days; 1: Retention 7-29 days with no monitoring; 2: Retention >= 30 days or basic monitoring/alerts exist; 3: Retention >= 90 days AND dedicated monitoring/alerts configured.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database lacks SQL Agent/msdb. Trend monitoring relies on Azure Monitor/Log Analytics or custom solutions.';
    SET @DatabaseQueried = 'master';
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
END
ELSE
BEGIN
    DECLARE @OldestHistoryDate DATE;
    DECLARE @HistoryRetentionDays INT;
    DECLARE @MonitoringJobCount INT;
    DECLARE @AlertCount INT;

    -- Calculate retention based on oldest history record (any status)
    SELECT @OldestHistoryDate = MIN(CONVERT(DATE, RIGHT('000000' + CAST(run_date AS VARCHAR(8)), 8)))
    FROM msdb.dbo.sysjobhistory
    WHERE run_date > 0;

    SET @HistoryRetentionDays = DATEDIFF(DAY, @OldestHistoryDate, CAST(GETDATE() AS DATE));
    IF @HistoryRetentionDays IS NULL SET @HistoryRetentionDays = 0;

    -- Proxy for monitoring jobs: names containing monitor/trend or commands querying sysjobhistory
    SELECT @MonitoringJobCount = COUNT(DISTINCT j.job_id)
    FROM msdb.dbo.sysjobs j
    INNER JOIN msdb.dbo.sysjobsteps js ON j.job_id = js.job_id
    WHERE j.name LIKE '%monitor%' OR j.name LIKE '%trend%' OR js.command LIKE '%sysjobhistory%';

    -- Proxy for alerts: alerts linked to jobs
    SELECT @AlertCount = COUNT(*)
    FROM msdb.dbo.sysalerts
    WHERE job_id IS NOT NULL;

    SET @Score = 0;
    IF @HistoryRetentionDays >= 90 AND (@MonitoringJobCount > 0 OR @AlertCount > 0)
        SET @Score = 3;
    ELSE IF @HistoryRetentionDays >= 30 OR @MonitoringJobCount > 0 OR @AlertCount > 0
        SET @Score = 2;
    ELSE IF @HistoryRetentionDays >= 7
        SET @Score = 1;

    SET @Finding = 'History retention: ' + CAST(@HistoryRetentionDays AS NVARCHAR(10)) + ' days; ';
    SET @Finding = @Finding + 'Monitoring jobs: ' + CAST(@MonitoringJobCount AS NVARCHAR(10)) + '; ';
    SET @Finding = @Finding + 'Job alerts: ' + CAST(@AlertCount AS NVARCHAR(10)) + '.';

    IF @Score = 0
        SET @Finding = 'No job history found or retention < 7 days. Trend monitoring not possible.';

    SET @DatabaseQueried = 'master';
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
END

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;