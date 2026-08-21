/*
    Checklist Item : 14.1.6 - Key lookups minimized via covering indexes where beneficial
    Scope          : SERVER (server-scoped DMVs cover every database on the instance)
    Access         : READ-ONLY. Only SELECTs against system DMVs; a #temp table is used for aggregation.
    Compatibility  : SQL Server 2012+ and Azure SQL Database (EngineEdition 5).
*/
SET NOCOUNT ON;

DECLARE @Result           NVARCHAR(50)   = N'Fail';
DECLARE @Score            INT            = 1;
DECLARE @DatabaseQueried  NVARCHAR(256)  = N'Server-wide (plan cache and missing index DMVs)';
DECLARE @Finding          NVARCHAR(MAX)  = N'';

DECLARE @SampledPlans     INT            = 0;
DECLARE @LookupPlans      INT            = 0;
DECLARE @LookupExecutions BIGINT         = 0;
DECLARE @CoveringRecs     INT            = 0;
DECLARE @LookupPct        DECIMAL(6,2)   = 0;
DECLARE @TopDatabases     NVARCHAR(1000) = N'';
DECLARE @ErrMsg           NVARCHAR(2000) = NULL;
DECLARE @IsAzureSqlDb     BIT            = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

BEGIN TRY

    IF OBJECT_ID('tempdb..#LookupPlans') IS NOT NULL
        DROP TABLE #LookupPlans;

    CREATE TABLE #LookupPlans
    (
        DatabaseName    NVARCHAR(128) NULL,
        ExecutionCount  BIGINT        NOT NULL,
        TotalWorkerTime BIGINT        NOT NULL,
        HasLookup       BIT           NOT NULL
    );

    /* Sample the most CPU-expensive cached plans and detect lookup operators in the showplan XML. */
    INSERT INTO #LookupPlans (DatabaseName, ExecutionCount, TotalWorkerTime, HasLookup)
    SELECT
        DB_NAME(NULLIF(st.dbid, 0)),
        tq.execution_count,
        tq.total_worker_time,
        CASE
            WHEN CHARINDEX(N'PhysicalOp="Key Lookup"', CONVERT(NVARCHAR(MAX), qp.query_plan)) > 0
              OR CHARINDEX(N'PhysicalOp="RID Lookup"', CONVERT(NVARCHAR(MAX), qp.query_plan)) > 0
            THEN 1
            ELSE 0
        END
    FROM
    (
        SELECT TOP (200)
            qs.plan_handle,
            qs.sql_handle,
            qs.execution_count,
            qs.total_worker_time
        FROM sys.dm_exec_query_stats AS qs
        ORDER BY qs.total_worker_time DESC
    ) AS tq
    OUTER APPLY sys.dm_exec_sql_text(tq.sql_handle) AS st
    CROSS APPLY sys.dm_exec_query_plan(tq.plan_handle) AS qp
    WHERE qp.query_plan IS NOT NULL;

    SELECT
        @SampledPlans     = COUNT(*),
        @LookupPlans      = SUM(CONVERT(INT, lp.HasLookup)),
        @LookupExecutions = SUM(CASE WHEN lp.HasLookup = 1 THEN lp.ExecutionCount ELSE 0 END)
    FROM #LookupPlans AS lp;

    SET @SampledPlans     = ISNULL(@SampledPlans, 0);
    SET @LookupPlans      = ISNULL(@LookupPlans, 0);
    SET @LookupExecutions = ISNULL(@LookupExecutions, 0);

    /* Outstanding covering-index recommendations: missing indexes that carry INCLUDE columns. */
    SELECT @CoveringRecs = COUNT(*)
    FROM sys.dm_db_missing_index_group_stats AS gs
    INNER JOIN sys.dm_db_missing_index_groups AS ig
        ON gs.group_handle = ig.index_group_handle
    INNER JOIN sys.dm_db_missing_index_details AS mid
        ON ig.index_handle = mid.index_handle
    WHERE mid.included_columns IS NOT NULL
      AND LEN(LTRIM(RTRIM(mid.included_columns))) > 0
      AND gs.avg_user_impact >= 50
      AND gs.user_seeks >= 100
      AND (mid.database_id > 4 OR @IsAzureSqlDb = 1);

    SET @CoveringRecs = ISNULL(@CoveringRecs, 0);

    IF @SampledPlans > 0
        SET @LookupPct = CONVERT(DECIMAL(6,2), @LookupPlans) * 100.0 / CONVERT(DECIMAL(6,2), @SampledPlans);

    SELECT @TopDatabases = STUFF
    (
        (
            SELECT TOP (5) N', ' + ISNULL(agg.DatabaseName, N'(unknown)')
            FROM
            (
                SELECT lp.DatabaseName, SUM(lp.ExecutionCount) AS TotalExecutions
                FROM #LookupPlans AS lp
                WHERE lp.HasLookup = 1
                GROUP BY lp.DatabaseName
            ) AS agg
            ORDER BY agg.TotalExecutions DESC
            FOR XML PATH(''), TYPE
        ).value('.', 'NVARCHAR(1000)'), 1, 2, N''
    );

    SET @TopDatabases = ISNULL(@TopDatabases, N'none');

    IF @SampledPlans = 0
    BEGIN
        SET @Score  = 2;
        SET @Finding = N'The plan cache contained no sampleable query plans (recent restart, cache flush, or plan-capture restrictions), so key-lookup prevalence could not be measured. '
                     + N'High-impact covering-index recommendations found: ' + CONVERT(NVARCHAR(20), @CoveringRecs) + N'. Re-run after a representative workload period.';
    END
    ELSE IF (@LookupPlans = 0 AND @CoveringRecs = 0)
         OR (@LookupPct <= 10.00 AND @CoveringRecs <= 3)
    BEGIN
        SET @Score  = 3;
        SET @Finding = N'Key lookups are minimized: ' + CONVERT(NVARCHAR(20), @LookupPlans) + N' of ' + CONVERT(NVARCHAR(20), @SampledPlans)
                     + N' sampled top-CPU cached plans (' + CONVERT(NVARCHAR(20), @LookupPct) + N'%) contain a Key Lookup or RID Lookup operator, with '
                     + CONVERT(NVARCHAR(20), @CoveringRecs) + N' outstanding high-impact missing-index recommendation(s) specifying INCLUDE columns. Affected databases: ' + @TopDatabases + N'.';
    END
    ELSE IF @LookupPct <= 30.00 AND @CoveringRecs <= 10
    BEGIN
        SET @Score  = 2;
        SET @Finding = N'Key lookups are only partially addressed: ' + CONVERT(NVARCHAR(20), @LookupPlans) + N' of ' + CONVERT(NVARCHAR(20), @SampledPlans)
                     + N' sampled top-CPU cached plans (' + CONVERT(NVARCHAR(20), @LookupPct) + N'%) contain a Key Lookup or RID Lookup operator, accounting for '
                     + CONVERT(NVARCHAR(30), @LookupExecutions) + N' execution(s), and ' + CONVERT(NVARCHAR(20), @CoveringRecs)
                     + N' high-impact missing-index recommendation(s) with INCLUDE columns remain unimplemented. Affected databases: ' + @TopDatabases + N'.';
    END
    ELSE
    BEGIN
        SET @Score  = 1;
        SET @Finding = N'Key lookups are not minimized: ' + CONVERT(NVARCHAR(20), @LookupPlans) + N' of ' + CONVERT(NVARCHAR(20), @SampledPlans)
                     + N' sampled top-CPU cached plans (' + CONVERT(NVARCHAR(20), @LookupPct) + N'%) contain a Key Lookup or RID Lookup operator, accounting for '
                     + CONVERT(NVARCHAR(30), @LookupExecutions) + N' execution(s), and ' + CONVERT(NVARCHAR(20), @CoveringRecs)
                     + N' high-impact missing-index recommendation(s) with INCLUDE columns are outstanding. Affected databases: ' + @TopDatabases + N'.';
    END

    IF OBJECT_ID('tempdb..#LookupPlans') IS NOT NULL
        DROP TABLE #LookupPlans;

END TRY
BEGIN CATCH

    SET @ErrMsg = ERROR_MESSAGE();
    SET @Score  = 2;
    SET @Finding = N'Key-lookup analysis could not be completed. Reading the plan cache and missing-index DMVs failed with: '
                 + ISNULL(@ErrMsg, N'unknown error')
                 + N'. Grant VIEW SERVER STATE (VIEW DATABASE STATE on Azure SQL Database) to the audit login and re-run; manual review is required until then.';

    IF OBJECT_ID('tempdb..#LookupPlans') IS NOT NULL
        DROP TABLE #LookupPlans;

END CATCH

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;