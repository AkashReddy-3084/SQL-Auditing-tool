/* Checklist 14.1.5 - Excessive/unnecessary sorts and spools addressed
   Read-only. Inspects showplan XML in the plan cache for Sort/Spool operators
   and tempdb spill warnings. Requires VIEW SERVER STATE. */
SET NOCOUNT ON;

DECLARE @TotalPlans    INT = 0,
        @SortPlans     INT = 0,
        @SpoolPlans    INT = 0,
        @AffectedPlans INT = 0,
        @SpillPlans    INT = 0,
        @Pct           DECIMAL(9,2) = 0,
        @TopDbs        NVARCHAR(1000) = N'',
        @Result        NVARCHAR(20) = N'Fail',
        @Score         INT = 1,
        @Finding       NVARCHAR(4000) = N'',
        @ErrMsg        NVARCHAR(2000) = N'';

IF OBJECT_ID('tempdb..#PlanScan') IS NOT NULL
    DROP TABLE #PlanScan;

CREATE TABLE #PlanScan
(
    RowId           INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    DatabaseName    NVARCHAR(128) NULL,
    TotalWorkerTime BIGINT NULL,
    ExecutionCount  BIGINT NULL,
    HasSort         BIT NOT NULL DEFAULT (0),
    HasSpool        BIT NOT NULL DEFAULT (0),
    HasSpill        BIT NOT NULL DEFAULT (0),
    QueryPlan       XML NULL
);

BEGIN TRY
    INSERT INTO #PlanScan (DatabaseName, TotalWorkerTime, ExecutionCount, QueryPlan)
    SELECT TOP (200)
           ISNULL(DB_NAME(qp.dbid), N'(unknown)'),
           qs.total_worker_time,
           qs.execution_count,
           qp.query_plan
    FROM sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
    WHERE qp.query_plan IS NOT NULL
    ORDER BY qs.total_worker_time DESC;

    UPDATE #PlanScan
    SET HasSort =
            CASE WHEN QueryPlan.exist('//*[local-name()="RelOp"][@PhysicalOp="Sort"]') = 1
                 THEN 1 ELSE 0 END,
        HasSpool =
            CASE WHEN QueryPlan.exist('//*[local-name()="RelOp"][@PhysicalOp="Table Spool" or @PhysicalOp="Index Spool" or @PhysicalOp="Row Count Spool" or @PhysicalOp="Window Spool"]') = 1
                 THEN 1 ELSE 0 END,
        HasSpill =
            CASE WHEN QueryPlan.exist('//*[local-name()="SpillToTempDb"]') = 1
                 THEN 1 ELSE 0 END;

    SELECT @TotalPlans    = COUNT(*),
           @SortPlans     = SUM(CASE WHEN HasSort  = 1 THEN 1 ELSE 0 END),
           @SpoolPlans    = SUM(CASE WHEN HasSpool = 1 THEN 1 ELSE 0 END),
           @AffectedPlans = SUM(CASE WHEN HasSort = 1 OR HasSpool = 1 THEN 1 ELSE 0 END),
           @SpillPlans    = SUM(CASE WHEN HasSpill = 1 THEN 1 ELSE 0 END)
    FROM #PlanScan;

    SELECT @TopDbs = STUFF(
        (
            SELECT TOP (5)
                   N', ' + agg.DatabaseName + N' (' + CAST(agg.Cnt AS NVARCHAR(10)) + N')'
            FROM (
                SELECT DatabaseName, COUNT(*) AS Cnt
                FROM #PlanScan
                WHERE HasSort = 1 OR HasSpool = 1
                GROUP BY DatabaseName
            ) AS agg
            ORDER BY agg.Cnt DESC
            FOR XML PATH(''), TYPE
        ).value('.', 'NVARCHAR(1000)'), 1, 2, N'');
END TRY
BEGIN CATCH
    SET @ErrMsg = ERROR_MESSAGE();
END CATCH

SET @TotalPlans    = ISNULL(@TotalPlans, 0);
SET @SortPlans     = ISNULL(@SortPlans, 0);
SET @SpoolPlans    = ISNULL(@SpoolPlans, 0);
SET @AffectedPlans = ISNULL(@AffectedPlans, 0);
SET @SpillPlans    = ISNULL(@SpillPlans, 0);
SET @TopDbs        = ISNULL(@TopDbs, N'');

IF @ErrMsg <> N''
BEGIN
    SET @Score = 1;
    SET @Finding = N'The plan cache could not be inspected. Error: ' + @ErrMsg
                 + N' VIEW SERVER STATE permission is required to read sys.dm_exec_query_stats and sys.dm_exec_query_plan, so no evidence that excessive sorts and spools have been addressed could be collected; manual review is required.';
END
ELSE IF @TotalPlans = 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'No cached query plans were available to analyse (the instance may have been restarted recently, the plan cache cleared, or the workload is idle), so no evidence that excessive sorts and spools have been addressed could be collected. Re-run after a representative workload has executed.';
END
ELSE
BEGIN
    SET @Pct = CAST(@AffectedPlans AS DECIMAL(9,2)) * 100.0 / CAST(@TotalPlans AS DECIMAL(9,2));

    SET @Finding = N'Analysed the ' + CAST(@TotalPlans AS NVARCHAR(10))
                 + N' most CPU-expensive cached plans: ' + CAST(@SortPlans AS NVARCHAR(10))
                 + N' contain Sort operators, ' + CAST(@SpoolPlans AS NVARCHAR(10))
                 + N' contain Spool operators (' + CAST(@AffectedPlans AS NVARCHAR(10))
                 + N' distinct plans, ' + CAST(@Pct AS NVARCHAR(10))
                 + N'% of those analysed), and ' + CAST(@SpillPlans AS NVARCHAR(10))
                 + N' carry tempdb spill warnings.'
                 + CASE WHEN @TopDbs <> N'' THEN N' Most affected databases: ' + @TopDbs + N'.' ELSE N'' END;

    IF @Pct <= 20 AND @SpillPlans = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = @Finding + N' Sort and spool usage is contained and no spills were observed, indicating excessive/unnecessary sorts and spools have been addressed.';
    END
    ELSE IF @Pct <= 40 AND @SpillPlans <= 2
    BEGIN
        SET @Score = 2;
        SET @Finding = @Finding + N' A noticeable minority of expensive plans still relies on sorts or spools, so tuning is broadly in place but not complete.';
    END
    ELSE IF @Pct <= 60
    BEGIN
        SET @Score = 1;
        SET @Finding = @Finding + N' A large share of the most expensive plans depends on sorts or spools, indicating unnecessary sorting and spooling has not been addressed.';
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = @Finding + N' The majority of the most expensive plans contain sorts or spools, showing that excessive and unnecessary sorts/spools are pervasive and untuned.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result,
       @Score  AS Score,
       CAST(N'SERVER' AS NVARCHAR(128)) AS DatabaseQueried,
       @Finding AS Finding;

IF OBJECT_ID('tempdb..#PlanScan') IS NOT NULL
    DROP TABLE #PlanScan;