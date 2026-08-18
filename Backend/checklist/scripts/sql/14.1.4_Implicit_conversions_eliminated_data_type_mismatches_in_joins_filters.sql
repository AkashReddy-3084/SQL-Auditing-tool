-- Checklist: 14.1.4 Implicit conversions eliminated (data-type mismatches in joins/filters)
-- Scope: SERVER
-- Scoring: 3=0 found, 2=1-3 found, 1=4-10 found, 0=>10 found

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #ImplicitConv (
    SqlHandle VARBINARY(64),
    QueryText NVARCHAR(4000)
);

INSERT INTO #ImplicitConv (SqlHandle, QueryText)
SELECT TOP 50 qs.sql_handle, LEFT(st.text, 4000)
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
WHERE qp.query_plan.exist('//RelOp[@ImplicitConversion]') = 1
  AND st.dbid > 4;

DECLARE @Count INT = (SELECT COUNT(*) FROM #ImplicitConv);

SET @Score = CASE
    WHEN @Count = 0 THEN 3
    WHEN @Count BETWEEN 1 AND 3 THEN 2
    WHEN @Count BETWEEN 4 AND 10 THEN 1
    ELSE 0
END;

DECLARE @Examples NVARCHAR(MAX) = (
    SELECT STRING_AGG(LEFT(QueryText, 500), '; ') WITHIN GROUP (ORDER BY QueryText)
    FROM (SELECT DISTINCT TOP 3 QueryText FROM #ImplicitConv) t
);

SET @Finding = CASE
    WHEN @Count = 0 THEN 'No implicit conversions found in cached execution plans.'
    ELSE 'Found ' + CAST(@Count AS NVARCHAR(10)) + ' queries with implicit conversions. Examples: ' + ISNULL(@Examples, 'None')
END;

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;

DROP TABLE #ImplicitConv;