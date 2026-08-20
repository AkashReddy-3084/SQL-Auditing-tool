-- Checklist: Key lookups minimized via covering indexes where beneficial
-- Scope: SERVER
-- Scoring: 3 = no key lookups in cache; 2 = 1-5 key lookups; 1 = 6-20 key lookups; 0 = >20 key lookups

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No plan cache data available';

-- Table to hold identified key lookups from the plan cache
CREATE TABLE #KeyLookups (
    ExecutionCount BIGINT
);

BEGIN TRY
    -- Extract plans containing the 'Key Lookup' operator
    -- We sum the execution counts of plans that contain a Key Lookup to determine the total volume of lookups
    INSERT INTO #KeyLookups (ExecutionCount)
    SELECT 
        qs.execution_count
    FROM sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
    WHERE CAST(qp.query_plan AS NVARCHAR(MAX)) LIKE '%Key Lookup%'
    -- We do not use TOP 100 here to ensure the count is accurate for scoring

    DECLARE @TotalLookups BIGINT = (SELECT SUM(ExecutionCount) FROM #KeyLookups);

    IF @TotalLookups IS NULL OR @TotalLookups = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = 'No key lookups found in the current plan cache.';
    END
    ELSE IF @TotalLookups <= 5
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Low number of key lookups found (' + CAST(@TotalLookups AS NVARCHAR(20)) + ')';
    END
    ELSE IF @TotalLookups <= 20
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Moderate number of key lookups found (' + CAST(@TotalLookups AS NVARCHAR(20)) + ')';
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'High number of key lookups found (' + CAST(@TotalLookups AS NVARCHAR(20)) + ')';
    END
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = 'Error analyzing plan cache: ' + ERROR_MESSAGE();
END CATCH;

DROP TABLE #KeyLookups;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;