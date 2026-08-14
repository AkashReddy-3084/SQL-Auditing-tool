-- Checklist: tempdb contention monitored and mitigated
-- Scope: SERVER
-- Scoring: 0=No mitigation/monitoring; 1=Partial mitigation OR monitoring only; 2=Full mitigation OR partial+monitoring; 3=Full mitigation AND monitoring
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

-- 1. Check Mitigation: tempdb data file count
DECLARE @FileCount INT = (SELECT COUNT(*) FROM sys.master_files WHERE database_id = 2 AND type = 0);

-- 2. Check Mitigation: Trace Flags 1117 & 1118
DECLARE @TF1117 INT = 0, @TF1118 INT = 0;
CREATE TABLE #TF (TraceFlag INT, Status INT, GlobalStatus INT, SessionStatus INT);
INSERT INTO #TF EXEC('DBCC TRACESTATUS(1117) WITH NO_INFOMSGS');
INSERT INTO #TF EXEC('DBCC TRACESTATUS(1118) WITH NO_INFOMSGS');
SELECT @TF1117 = ISNULL(MAX(GlobalStatus), 0) FROM #TF WHERE TraceFlag = 1117;
SELECT @TF1118 = ISNULL(MAX(GlobalStatus), 0) FROM #TF WHERE TraceFlag = 1118;
DROP TABLE #TF;

-- 3. Check Mitigation: SQL 2019+ tempdb metadata memory grant settings
DECLARE @SQL2019Mitigation INT = 0;
IF EXISTS (SELECT 1 FROM sys.configurations WHERE name IN ('tempdb_metadata_memory_grant_clerk_memory_kb', 'tempdb_metadata_memory_grant_percent'))
BEGIN
    SELECT @SQL2019Mitigation = CASE WHEN SUM(value) > 0 THEN 1 ELSE 0 END
    FROM sys.configurations
    WHERE name IN ('tempdb_metadata_memory_grant_clerk_memory_kb', 'tempdb_metadata_memory_grant_percent');
END

-- Evaluate Mitigation Level
DECLARE @MitigationLevel INT = 0;
IF @FileCount >= 2 AND (@TF1117 = 1 OR @TF1118 = 1 OR @SQL2019Mitigation = 1)
    SET @MitigationLevel = 2; -- Full mitigation
ELSE IF @FileCount >= 2 OR @TF1117 = 1 OR @TF1118 = 1 OR @SQL2019Mitigation = 1
    SET @MitigationLevel = 1; -- Partial mitigation
ELSE
    SET @MitigationLevel = 0; -- No mitigation

-- 4. Check Monitoring: SQL Agent Jobs for tempdb/wait stats/contention
DECLARE @MonitoringLevel INT = 0;
DECLARE @JobCount INT = (SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name LIKE '%tempdb%' OR name LIKE '%contention%' OR name LIKE '%wait%');
IF @JobCount > 0 SET @MonitoringLevel = 1;

-- Combine for final score
IF @MitigationLevel = 2 AND @MonitoringLevel >= 1 SET @Score = 3;
ELSE IF @MitigationLevel = 2 OR (@MitigationLevel = 1 AND @MonitoringLevel >= 1) SET @Score = 2;
ELSE IF @MitigationLevel = 1 OR @MonitoringLevel >= 1 SET @Score = 1;
ELSE SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;