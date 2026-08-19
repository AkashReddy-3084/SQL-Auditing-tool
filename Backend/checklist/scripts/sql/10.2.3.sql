-- Checklist: DMVs used for ongoing performance analysis (waits, missing/unused indexes)
-- Scope: SERVER
-- Scoring: 3 = multiple performance DMVs queried recently; 2 = at least one DMV queried; 1 = minimal evidence; 0 = no evidence of DMV usage in cache

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No evidence of performance DMV usage found in plan cache';

DECLARE @DmvCount INT = 0;
DECLARE @DmvList NVARCHAR(MAX) = '';

-- Create a list of target DMVs to look for in the plan cache
CREATE TABLE #TargetDMVs (DmvName NVARCHAR(255));
INSERT INTO #TargetDMVs VALUES 
('sys.dm_os_wait_stats'), 
('sys.dm_exec_query_stats'), 
('sys.dm_db_missing_index_details'), 
('sys.dm_db_index_usage_stats'), 
('sys.dm_exec_requests'), 
('sys.dm_os_performance_counters'),
('sys.dm_exec_cached_plans');

-- Search the plan cache for queries referencing these DMVs
SELECT 
    @DmvCount = COUNT(DISTINCT t.DmvName),
    @DmvList = STRING_AGG(CAST(t.DmvName AS NVARCHAR(MAX)), ', ')
FROM #TargetDMVs t
JOIN sys.dm_exec_query_stats qs ON 1=1
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
WHERE st.text LIKE '%' + t.DmvName + '%';

IF @DmvCount >= 3
BEGIN
    SET @Score = 3;
    SET @Finding = 'Multiple performance DMVs queried: ' + ISNULL(@DmvList, '');
END
ELSE IF @DmvCount >= 1
BEGIN
    SET @Score = 2;
    SET @Finding = 'Performance DMVs queried: ' + ISNULL(@DmvList, '');
END
ELSE IF EXISTS (SELECT 1 FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st WHERE st.text LIKE '%sys.dm_%')
BEGIN
    SET @Score = 1;
    SET @Finding = 'Minimal evidence: General DMVs queried, but no specific performance DMVs from the target list found.';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = 'No evidence of performance DMV usage found in plan cache';
END

DROP TABLE #TargetDMVs;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;