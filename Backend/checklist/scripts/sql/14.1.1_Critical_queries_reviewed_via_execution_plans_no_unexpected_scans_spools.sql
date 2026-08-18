-- Checklist: Critical queries reviewed via execution plans (no unexpected scans/spools)
-- Scope: SERVER
-- Scoring: 0: >10 cached queries with scans/spools; 1: 3-10; 2: 1-2; 3: 0. Proxy check requires human review for full compliance.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #PlanIssues (
    DbName NVARCHAR(128),
    QueryHash BINARY(8),
    StatementText NVARCHAR(4000),
    OperatorType NVARCHAR(100)
);

INSERT INTO #PlanIssues
SELECT DISTINCT
    DB_NAME(st.dbid) AS DbName,
    qs.query_hash,
    SUBSTRING(st.text, (qs.statement_start_offset/2)+1, 
        ((CASE qs.statement_end_offset 
            WHEN -1 THEN DATALENGTH(st.text)
            ELSE qs.statement_end_offset
        END - qs.statement_start_offset)/2)+1) AS StatementText,
    CASE 
        WHEN qp.query_plan LIKE '%<IndexScan%' THEN 'Index Scan'
        WHEN qp.query_plan LIKE '%<ClusteredIndexScan%' THEN 'Clustered Index Scan'
        WHEN qp.query_plan LIKE '%<TableScan%' THEN 'Table Scan'
        WHEN qp.query_plan LIKE '%<Spool%' THEN 'Spool'
    END AS OperatorType
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
WHERE st.dbid > 4 
  AND st.dbid <> 32767
  AND (qp.query_plan LIKE '%<IndexScan%' 
       OR qp.query_plan LIKE '%<ClusteredIndexScan%' 
       OR qp.query_plan LIKE '%<TableScan%' 
       OR qp.query_plan LIKE '%<Spool%');

DECLARE @IssueCount INT = (SELECT COUNT(DISTINCT QueryHash) FROM #PlanIssues);
DECLARE @SampleFindings NVARCHAR(MAX) = (
    SELECT STRING_AGG(CONCAT(DbName, ': ', LEFT(StatementText, 100), ' (', OperatorType, ')'), '; ')
    FROM (SELECT DISTINCT TOP 5 DbName, StatementText, OperatorType FROM #PlanIssues) t
);

SET @DatabaseQueried = 'master';

IF @IssueCount = 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'No cached queries with unexpected scans or spools found. NOTE: This script provides automated evidence. Full compliance requires human review.';
END
ELSE IF @IssueCount <= 2
BEGIN
    SET @Score = 2;
    SET @Finding = CONCAT('Found ', @IssueCount, ' cached query(s) with scans/spools. Examples: ', ISNULL(@SampleFindings, 'None'));
END
ELSE IF @IssueCount <= 10
BEGIN
    SET @Score = 1;
    SET @Finding = CONCAT('Found ', @IssueCount, ' cached query(s) with scans/spools. Examples: ', ISNULL(@SampleFindings, 'None'));
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = CONCAT('Found ', @IssueCount, ' cached query(s) with scans/spools. Examples: ', ISNULL(@SampleFindings, 'None'));
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;

DROP TABLE #PlanIssues;