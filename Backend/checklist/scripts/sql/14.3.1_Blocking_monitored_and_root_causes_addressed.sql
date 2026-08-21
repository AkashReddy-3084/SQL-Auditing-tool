-- Checklist: Blocking monitored and root causes addressed
-- Scope: SERVER
-- Scoring: 0=Fail (High blocking/waits, no monitoring), 1=Partial (Moderate issues or no monitoring), 2=Pass (Low issues, monitoring configured), 3=Pass (Negligible issues, robust monitoring). Note: Root cause resolution requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @BlockingCount INT = 0;
DECLARE @LckWaitMs BIGINT = 0;
DECLARE @TotalWaitMs BIGINT = 0;
DECLARE @LckPct DECIMAL(5,2) = 0;
DECLARE @MonExists BIT = 0;
DECLARE @MonDetail NVARCHAR(MAX) = 'None detected';
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

-- Active blocking sessions
SELECT @BlockingCount = COUNT(*) FROM sys.dm_os_waiting_tasks WHERE blocking_session_id > 0;

-- Wait statistics for blocking
SELECT @LckWaitMs = ISNULL(SUM(wait_time_ms), 0), @TotalWaitMs = ISNULL(SUM(wait_time_ms), 1)
FROM sys.dm_os_wait_stats
WHERE wait_type LIKE 'LCK_M_%';

IF @TotalWaitMs > 0
    SET @LckPct = (@LckWaitMs * 100.0) / @TotalWaitMs;

-- Monitoring check (platform-aware)
IF @EngineEdition <> 5 -- SQL Server / Azure SQL MI
BEGIN
    BEGIN TRY
        IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name LIKE '%block%' OR name LIKE '%deadlock%')
        BEGIN
            SET @MonExists = 1;
            SET @MonDetail = 'SQL Agent job(s) found';
        END
        ELSE IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name LIKE '%block%' OR name LIKE '%deadlock%')
        BEGIN
            SET @MonExists = 1;
            SET @MonDetail = 'Extended Event session(s) found';
        END
    END TRY
    BEGIN CATCH
        SET @MonDetail = 'Permission denied or unavailable';
    END CATCH
END
ELSE -- Azure SQL Database
BEGIN
    SET @MonDetail = 'Not applicable (Azure SQL DB)';
END

-- Determine Score
SET @Score = 0;
IF @BlockingCount <= 5 AND @LckPct <= 10.0
BEGIN
    SET @Score = 1;
    IF @MonExists = 1
        SET @Score = 2;
    IF @BlockingCount = 0 AND @LckPct < 1.0 AND @MonExists = 1
        SET @Score = 3;
END

-- Construct Finding
SET @Finding = 'Active blocking sessions: ' + CAST(@BlockingCount AS NVARCHAR(10)) + '; ';
SET @Finding += 'LCK_M_* wait percentage: ' + CAST(@LckPct AS NVARCHAR(10)) + '%; ';
SET @Finding += 'Monitoring: ' + @MonDetail + '; ';

IF @Score < 3
    SET @Finding += 'NOTE: This script provides automated evidence. Full compliance requires human review.';

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;