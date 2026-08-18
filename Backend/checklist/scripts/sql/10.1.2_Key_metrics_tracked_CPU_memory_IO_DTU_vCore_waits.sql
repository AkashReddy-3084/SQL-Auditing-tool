-- Checklist: Key metrics tracked (CPU, memory, IO, DTU/vCore, waits)
-- Scope: SERVER
-- Scoring: 0: No monitoring infrastructure found. 1: 1-2 metric categories tracked. 2: 3-4 metric categories tracked. 3: All 5 metric categories tracked.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

CREATE TABLE #MetricsFound (
    MetricCategory NVARCHAR(50),
    SourceType NVARCHAR(20),
    SourceName NVARCHAR(256)
);

-- Check SQL Agent Jobs (SQL Server / Azure SQL MI only)
IF @EngineEdition NOT IN (5)
BEGIN
    INSERT INTO #MetricsFound (MetricCategory, SourceType, SourceName)
    SELECT 'CPU', 'Job', name FROM msdb.dbo.sysjobs WHERE name LIKE '%cpu%' OR name LIKE '%processor%'
    UNION ALL
    SELECT 'Memory', 'Job', name FROM msdb.dbo.sysjobs WHERE name LIKE '%memory%' OR name LIKE '%buffer%' OR name LIKE '%page%'
    UNION ALL
    SELECT 'IO', 'Job', name FROM msdb.dbo.sysjobs WHERE name LIKE '%io%' OR name LIKE '%disk%' OR name LIKE '%storage%'
    UNION ALL
    SELECT 'DTU/vCore', 'Job', name FROM msdb.dbo.sysjobs WHERE name LIKE '%dtu%' OR name LIKE '%vcore%' OR name LIKE '%compute%'
    UNION ALL
    SELECT 'Waits', 'Job', name FROM msdb.dbo.sysjobs WHERE name LIKE '%wait%' OR name LIKE '%blocking%' OR name LIKE '%lock%';
END

-- Check Extended Event Sessions (All platforms)
INSERT INTO #MetricsFound (MetricCategory, SourceType, SourceName)
SELECT 'CPU', 'XE', name FROM sys.server_event_sessions WHERE name LIKE '%cpu%' OR name LIKE '%processor%'
UNION ALL
SELECT 'Memory', 'XE', name FROM sys.server_event_sessions WHERE name LIKE '%memory%' OR name LIKE '%buffer%' OR name LIKE '%page%'
UNION ALL
SELECT 'IO', 'XE', name FROM sys.server_event_sessions WHERE name LIKE '%io%' OR name LIKE '%disk%' OR name LIKE '%storage%'
UNION ALL
SELECT 'DTU/vCore', 'XE', name FROM sys.server_event_sessions WHERE name LIKE '%dtu%' OR name LIKE '%vcore%' OR name LIKE '%compute%'
UNION ALL
SELECT 'Waits', 'XE', name FROM sys.server_event_sessions WHERE name LIKE '%wait%' OR name LIKE '%blocking%' OR name LIKE '%lock%';

-- Aggregate findings
DECLARE @DistinctMetrics INT = (SELECT COUNT(DISTINCT MetricCategory) FROM #MetricsFound);
DECLARE @TrackedList NVARCHAR(MAX) = (SELECT STRING_AGG(DISTINCT MetricCategory, ', ') FROM #MetricsFound);
DECLARE @SourcesList NVARCHAR(MAX) = (SELECT STRING_AGG(SourceType + ': ' + SourceName, '; ') FROM #MetricsFound);

SET @Score = CASE
    WHEN @DistinctMetrics = 5 THEN 3
    WHEN @DistinctMetrics >= 3 THEN 2
    WHEN @DistinctMetrics >= 1 THEN 1
    ELSE 0
END;

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding = CASE
    WHEN @DistinctMetrics = 0 THEN 'No monitoring jobs or Extended Event sessions found tracking key performance metrics.'
    ELSE 'Tracked metrics: ' + ISNULL(@TrackedList, 'None') + '. Sources: ' + ISNULL(@SourcesList, 'None')
END;

DROP TABLE #MetricsFound;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;