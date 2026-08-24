SET NOCOUNT ON;

DECLARE @CostThreshold decimal(18,2);
DECLARE @ExpensiveSerialPlans bigint = 0;
DECLARE @PotentiallyUnnecessarySerialPlans bigint = 0;
DECLARE @PotentiallyUnnecessaryPercent decimal(9,2) = 0;
DECLARE @Result nvarchar(20) = N'Fail';
DECLARE @Score int = 0;
DECLARE @Finding nvarchar(4000);

BEGIN TRY
    SELECT @CostThreshold = CONVERT(decimal(18,2), value_in_use)
    FROM sys.configurations
    WHERE name = N'cost threshold for parallelism';

    ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'),
    CachedStatements AS
    (
        SELECT
            StatementNode.value('@StatementSubTreeCost', 'float') AS StatementSubTreeCost,
            NULLIF(
                StatementNode.value('(QueryPlan/@NonParallelPlanReason)[1]', 'nvarchar(256)'),
                N''
            ) AS NonParallelPlanReason,
            StatementNode.value('(QueryPlan/@DegreeOfParallelism)[1]', 'int') AS DegreeOfParallelism
        FROM sys.dm_exec_query_stats AS QueryStats
        CROSS APPLY sys.dm_exec_query_plan(QueryStats.plan_handle) AS QueryPlan
        CROSS APPLY QueryPlan.query_plan.nodes('//StmtSimple[QueryPlan]') AS Statements(StatementNode)
        WHERE QueryPlan.query_plan IS NOT NULL
    )
    SELECT
        @ExpensiveSerialPlans = COUNT_BIG(*),
        @PotentiallyUnnecessarySerialPlans = COALESCE(SUM(
            CASE WHEN NonParallelPlanReason IS NULL THEN CONVERT(bigint, 1) ELSE CONVERT(bigint, 0) END
        ), 0)
    FROM CachedStatements
    WHERE StatementSubTreeCost >= @CostThreshold
      AND DegreeOfParallelism = 1;

    SET @PotentiallyUnnecessaryPercent =
        CASE
            WHEN @ExpensiveSerialPlans = 0 THEN 0
            ELSE CONVERT(decimal(9,2),
                100.0 * @PotentiallyUnnecessarySerialPlans / @ExpensiveSerialPlans)
        END;

    SET @Score =
        CASE
            WHEN @PotentiallyUnnecessarySerialPlans = 0 THEN 3
            WHEN @PotentiallyUnnecessaryPercent <= 5.00 THEN 2
            WHEN @PotentiallyUnnecessaryPercent <= 20.00 THEN 1
            ELSE 0
        END;

    SET @Result =
        CASE
            WHEN @Score = 3 THEN N'Pass'
            WHEN @Score IN (1, 2) THEN N'Partial'
            ELSE N'Fail'
        END;

    SET @Finding = CONCAT(
        N'Cost threshold for parallelism is ', @CostThreshold,
        N'. Cached expensive serial statements: ', @ExpensiveSerialPlans,
        N'; statements without an explicit nonparallel reason: ',
        @PotentiallyUnnecessarySerialPlans, N' (',
        @PotentiallyUnnecessaryPercent, N'%).'
    );
END TRY
BEGIN CATCH
    SET @Result = N'Fail';
    SET @Score = 0;
    SET @Finding = CONCAT(
        N'Unable to inspect cached execution plans: ', ERROR_MESSAGE(),
        N'. VIEW SERVER STATE (or VIEW SERVER PERFORMANCE STATE on SQL Server 2022 and later) may be required.'
    );
END CATCH;

SELECT
    @Result AS Result,
    @Score AS Score,
    CONVERT(nvarchar(128), N'SERVER') AS DatabaseQueried,
    @Finding AS Finding;