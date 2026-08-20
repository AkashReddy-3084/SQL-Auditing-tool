-- Checklist: Plan cache health reviewed (no excessive single-use plans / bloat)
-- Scope: SERVER
-- Scoring: 3 = < 5% single-use plans; 2 = 5-20% single-use plans; 1 = 20-50% single-use plans; 0 = > 50% single-use plans

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Could not determine plan cache health';

DECLARE @TotalPlans INT = 0;
DECLARE @SingleUsePlans INT = 0;
DECLARE @Ratio FLOAT = 0;

BEGIN TRY
    -- Count total cached plans and those used only once
    SELECT 
        @TotalPlans = COUNT(*),
        @SingleUsePlans = SUM(CASE WHEN execution_count = 1 THEN 1 ELSE 0 END)
    FROM sys.dm_exec_cached_plans cp
    CROSS APPLY sys.dm_exec_query_stats qs 
    WHERE cp.plan_handle = qs.plan_handle;

    IF @TotalPlans > 0
    BEGIN
        SET @Ratio = CAST(@SingleUsePlans AS FLOAT) / CAST(@TotalPlans AS FLOAT);
        
        IF @Ratio < 0.05
        BEGIN
            SET @Score = 3;
        END
        ELSE IF @Ratio < 0.20
        BEGIN
            SET @Score = 2;
        END
        ELSE IF @Ratio < 0.50
        BEGIN
            SET @Score = 1;
        END
        ELSE
        BEGIN
            SET @Score = 0;
        END

        SET @Finding = 'Total Plans: ' + CAST(@TotalPlans AS NVARCHAR(20)) + 
                       ', Single-Use Plans: ' + CAST(@SingleUsePlans AS NVARCHAR(20)) + 
                       ', Ratio: ' + CAST(CAST(@Ratio * 100 AS DECIMAL(5,2)) AS NVARCHAR(10)) + '%';
    END
    ELSE
    BEGIN
        SET @Score = 3;
        SET @Finding = 'No cached plans found in sys.dm_exec_cached_plans';
    END
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = 'Error querying plan cache: ' + ERROR_MESSAGE();
END CATCH

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;