-- Checklist: tempdb contention monitored and mitigated
-- Scope: SERVER
-- Scoring: 
-- 3: TF 1117 & 1118 enabled, >=2 equal-sized tempdb data files, PAGELATCH/PAGEOLATCH waits < 1% of total, monitoring job/trace exists.
-- 2: TF 1117 & 1118 enabled, >=2 tempdb data files, waits < 5%, monitoring partially configured.
-- 1: TFs enabled but single data file, or waits 5-15%, no monitoring.
-- 0: TFs disabled, single data file, or waits > 15%, no monitoring.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @ProductMajorVersion INT = CONVERT(INT, SERVERPROPERTY('ProductMajorVersion'));
DECLARE @TF1117 INT = 0;
DECLARE @TF1118 INT = 0;
DECLARE @TempDbFileCount INT = 0;
DECLARE @TempDbFilesEqual BIT = 0;
DECLARE @LatchWaitMs BIGINT = 0;
DECLARE @TotalWaitMs BIGINT = 0;
DECLARE @MonitoringJobExists BIT = 0;
DECLARE @Finding NVARCHAR(MAX) = '';
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10);
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';

-- 1. Check Trace Flags (1117 & 1118)
IF @EngineEdition <> 5 -- On-prem / MI
BEGIN
    CREATE TABLE #TF (TraceFlag INT, Status INT, GlobalStatus INT, SessionStatus INT);
    INSERT INTO #TF EXEC('DBCC TRACESTATUS(1117) WITH NO_INFOMSGS');
    SET @TF1117 = ISNULL((SELECT GlobalStatus FROM #TF WHERE TraceFlag = 1117), 0);
    DELETE #TF;
    INSERT INTO #TF EXEC('DBCC TRACESTATUS(1118) WITH NO_INFOMSGS');
    SET @TF1118 = ISNULL((SELECT GlobalStatus FROM #TF WHERE TraceFlag = 1118), 0);
    DROP TABLE #TF;

    -- SQL 2016+ enables these by default
    IF @ProductMajorVersion >= 13 AND @TF1117 = 0 AND @TF1118 = 0
    BEGIN
        SET @TF1117 = 1;
        SET @TF1118 = 1;
    END
END
ELSE
BEGIN
    -- Azure SQL DB manages tempdb optimization automatically
    SET @TF1117 = 1;
    SET @TF1118 = 1;
END

-- 2. Check tempdb Data Files
IF @EngineEdition <> 5
BEGIN
    SELECT @TempDbFileCount = COUNT(*),
           @TempDbFilesEqual = CASE WHEN COUNT(*) > 1 AND MIN(size) = MAX(size) THEN 1 ELSE 0 END
    FROM sys.master_files
    WHERE database_id = 2 AND type = 0;
END
ELSE
BEGIN
    SET @TempDbFileCount = 2;
    SET @TempDbFilesEqual = 1;
END

-- 3. Check Wait Stats for Contention
SELECT @LatchWaitMs = SUM(wait_time_ms),
       @TotalWaitMs = SUM(wait_time_ms)
FROM sys.dm_os_wait_stats
WHERE wait_type IN ('PAGELATCH_UP', 'PAGELATCH_EX', 'PAGEOLATCH_UP', 'PAGEOLATCH_EX');

-- 4. Check for Monitoring Jobs
IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name LIKE '%tempdb%' OR name LIKE '%contention%' OR name LIKE '%wait%')
        SET @MonitoringJobExists = 1;
END

-- 5. Calculate Score
DECLARE @LatchPct FLOAT = CASE WHEN @TotalWaitMs > 0 THEN (@LatchWaitMs * 100.0 / @TotalWaitMs) ELSE 0 END;

IF @TF1117 = 1 AND @TF1118 = 1 AND @TempDbFileCount >= 2 AND @TempDbFilesEqual = 1 AND @LatchPct < 1.0 AND @MonitoringJobExists = 1
    SET @Score = 3;
ELSE IF @TF1117 = 1 AND @TF1118 = 1 AND @TempDbFileCount >= 2 AND @LatchPct < 5.0
    SET @Score = 2;
ELSE IF @TF1117 = 1 AND @TF1118 = 1 AND @TempDbFileCount = 1
    SET @Score = 1;
ELSE IF @LatchPct >= 5.0 OR (@TF1117 = 0 AND @TF1118 = 0)
    SET @Score = 0;
ELSE
    SET @Score = 1;

-- 6. Build Finding
SET @Finding = 'TF1117=' + CAST(@TF1117 AS NVARCHAR(10)) + ', TF1118=' + CAST(@TF1118 AS NVARCHAR(10)) + 
               ', TempDbDataFiles=' + CAST(@TempDbFileCount AS NVARCHAR(10)) + 
               ', EqualSize=' + CAST(@TempDbFilesEqual AS NVARCHAR(10)) + 
               ', LatchWaitPct=' + CAST(ROUND(@LatchPct, 2) AS NVARCHAR(10)) + '%' + 
               ', MonitoringJob=' + CAST(@MonitoringJobExists AS NVARCHAR(10));

IF @Score = 3 SET @Finding = @Finding + ' | Fully mitigated and monitored.';
ELSE IF @Score = 2 SET @Finding = @Finding + ' | Mitigated, minor gaps in monitoring or file sizing.';
ELSE IF @Score = 1 SET @Finding = @Finding + ' | Partial mitigation, contention risk present.';
ELSE SET @Finding = @Finding + ' | High contention risk, mitigation missing.';

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;