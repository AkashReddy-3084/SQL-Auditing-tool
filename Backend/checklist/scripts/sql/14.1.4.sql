-- Checklist: Implicit conversions eliminated (data-type mismatches in joins/filters)
-- Scope: SERVER
-- Scoring: 3 = no plan-affecting conversions found; 2 = 1-5 instances; 1 = 6-20 instances; 0 = >20 instances

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No plan-affecting conversions found';

DECLARE @ConversionCount INT = 0;
DECLARE @Details NVARCHAR(MAX) = '';

-- Use a temp table to collect plan-affecting conversions from the plan cache
IF OBJECT_ID('tempdb..#FoundConversions') IS NOT NULL DROP TABLE #FoundConversions;

SELECT 
    cp.plan_handle, 
    st.text
INTO #FoundConversions
FROM sys.dm_exec_cached_plans cp
CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) qp
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) st
WHERE CAST(qp.query_plan AS NVARCHAR(MAX)) LIKE '%PlanAffectingConvert="True"%'
  AND st.text NOT LIKE '%sys.dm_exec_cached_plans%';

SELECT @ConversionCount = COUNT(*) FROM #FoundConversions;

IF @ConversionCount > 0
BEGIN
    -- Collect a sample of the query text for the finding using a cursor for compatibility
    DECLARE @SampleText NVARCHAR(MAX);
    DECLARE SampleCursor CURSOR LOCAL FAST_FORWARD FOR 
        SELECT TOP 5 CAST(LEFT(text, 100) AS NVARCHAR(MAX)) FROM #FoundConversions;
    
    OPEN SampleCursor;
    FETCH NEXT FROM SampleCursor INTO @SampleText;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Details = @Details + CASE WHEN @Details = '' THEN '' ELSE ' | ' END + @SampleText;
        FETCH NEXT FROM SampleCursor INTO @SampleText;
    END
    CLOSE SampleCursor;
    DEALLOCATE SampleCursor;
    
    SET @Finding = 'Found ' + CAST(@ConversionCount AS NVARCHAR(10)) + ' plan-affecting implicit conversions. Sample: ' + @Details;
    
    SET @Score = CASE 
        WHEN @ConversionCount <= 5 THEN 2 
        WHEN @ConversionCount <= 20 THEN 1 
        ELSE 0 
    END;
END
ELSE
BEGIN
    SET @Score = 3;
    SET @Finding = 'No plan-affecting implicit conversions detected in the current plan cache.';
END

IF OBJECT_ID('tempdb..#FoundConversions') IS NOT NULL DROP TABLE #FoundConversions;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;