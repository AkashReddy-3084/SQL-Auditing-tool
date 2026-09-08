/*
    Checklist Item : 14.1.1 - Critical queries reviewed via execution plans (no unexpected scans/spools)
    Scope          : SERVER
    Purpose        : Read-only proxy check. Inspects the cached execution plans of the most
                     CPU-expensive queries on the instance and counts Table Scan and Spool
                     operators - the classic symptoms of plans that have never been reviewed
                     or tuned.
    Safety         : SELECT-only against DMVs, plus session-local temp tables. No user data,
                     configuration or state is modified.
*/
SET NOCOUNT ON;

DECLARE @Result          NVARCHAR(50);
DECLARE @Score           INT = 1;
DECLARE @Finding         NVARCHAR(MAX) = N'';
DECLARE @DatabaseQueried NVARCHAR(256) = N'N/A (Server-level plan cache)';
DECLARE @IsAzureDb       BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @HasPerm         BIT = 0;

/* Plan-cache DMVs need VIEW SERVER STATE on a box instance, VIEW DATABASE STATE on Azure SQL Database. */
IF @IsAzureDb = 1
    SET @HasPerm = CASE WHEN HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'VIEW DATABASE STATE') = 1 THEN 1 ELSE 0 END;
ELSE
    SET @HasPerm = CASE WHEN HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE') = 1 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#TopPlans') IS NOT NULL DROP TABLE #TopPlans;
IF OBJECT_ID('tempdb..#PlanOps')  IS NOT NULL DROP TABLE #PlanOps;

CREATE TABLE #TopPlans
(
    RowId             INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    DatabaseName      NVARCHAR(256) NULL,
    ExecutionCount    BIGINT        NULL,
    TotalWorkerTimeMs BIGINT        NULL,
    TotalLogicalReads BIGINT        NULL,
    QueryText         NVARCHAR(300) NULL,
    QueryPlan         XML           NULL
);

CREATE TABLE #PlanOps
(
    RowId           INT NOT NULL PRIMARY KEY,
    TableScanCount  INT NOT NULL,
    SpoolCount      INT NOT NULL,
    IndexScanCount  INT NOT NULL
);

DECLARE @Analyzed        INT = 0;
DECLARE @Flagged         INT = 0;
DECLARE @TotalTableScans INT = 0;
DECLARE @TotalSpools     INT = 0;
DECLARE @TotalIndexScans INT = 0;
DECLARE @PctFlagged      DECIMAL(9,1) = 0;
DECLARE @Sample          NVARCHAR(MAX) = N'';
DECLARE @DbList          NVARCHAR(MAX) = N'';

IF @HasPerm = 0
BEGIN
    SET @Score   = 1;
    SET @Finding = N'The audit login does not hold VIEW SERVER STATE (or VIEW DATABASE STATE on Azure SQL Database), so the execution plan cache could not be read and scan/spool quality could not be assessed. Execution plans for the critical queries must be reviewed manually and the evidence supplied.';
END
ELSE
BEGIN
    /* Top 25 cached plans by CPU. System databases are excluded on box instances only;
       on Azure SQL Database the single user database must never be filtered out. */
    INSERT INTO #TopPlans (DatabaseName, ExecutionCount, TotalWorkerTimeMs, TotalLogicalReads, QueryText, QueryPlan)
    SELECT TOP (25)
           ISNULL(DB_NAME(qp.dbid), N'(adhoc/unknown)')                                       AS DatabaseName,
           qs.execution_count                                                                 AS ExecutionCount,
           qs.total_worker_time / 1000                                                        AS TotalWorkerTimeMs,
           qs.total_logical_reads                                                             AS TotalLogicalReads,
           LEFT(LTRIM(REPLACE(REPLACE(REPLACE(ISNULL(st.text, N''), CHAR(13), N' '), CHAR(10), N' '), CHAR(9), N' ')), 300) AS QueryText,
           qp.query_plan                                                                      AS QueryPlan
    FROM sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
    OUTER APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS st
    WHERE qp.query_plan IS NOT NULL
      AND (@IsAzureDb = 1 OR qp.dbid IS NULL OR qp.dbid NOT IN (1, 2, 3, 4, 32767))
    ORDER BY qs.total_worker_time DESC;

    /* Count the operators of interest inside each plan. Namespace is declared inline in the XQuery. */
    INSERT INTO #PlanOps (RowId, TableScanCount, SpoolCount, IndexScanCount)
    SELECT tp.RowId,
           tp.QueryPlan.value('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan"; count(//RelOp[@PhysicalOp="Table Scan"])', 'int'),
           tp.QueryPlan.value('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan"; count(//RelOp[contains(@PhysicalOp,"Spool")])', 'int'),
           tp.QueryPlan.value('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan"; count(//RelOp[@PhysicalOp="Clustered Index Scan" or @PhysicalOp="Index Scan"])', 'int')
    FROM #TopPlans AS tp
    WHERE tp.QueryPlan IS NOT NULL;

    SELECT @Analyzed        = COUNT(*),
           @Flagged         = ISNULL(SUM(CASE WHEN po.TableScanCount > 0 OR po.SpoolCount > 0 THEN 1 ELSE 0 END), 0),
           @TotalTableScans = ISNULL(SUM(po.TableScanCount), 0),
           @TotalSpools     = ISNULL(SUM(po.SpoolCount), 0),
           @TotalIndexScans = ISNULL(SUM(po.IndexScanCount), 0)
    FROM #PlanOps AS po;

    SET @Analyzed        = ISNULL(@Analyzed, 0);
    SET @Flagged         = ISNULL(@Flagged, 0);
    SET @TotalTableScans = ISNULL(@TotalTableScans, 0);
    SET @TotalSpools     = ISNULL(@TotalSpools, 0);
    SET @TotalIndexScans = ISNULL(@TotalIndexScans, 0);

    SET @DbList = ISNULL(STUFF((SELECT DISTINCT N', ' + tp.DatabaseName
                                FROM #TopPlans AS tp
                                FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'(none)');

    SET @Sample = ISNULL(STUFF((SELECT TOP (5)
                                       N' | ' + tp.DatabaseName
                                     + N' [tableScans=' + CAST(po.TableScanCount AS NVARCHAR(10))
                                     + N', spools='     + CAST(po.SpoolCount AS NVARCHAR(10))
                                     + N', indexScans=' + CAST(po.IndexScanCount AS NVARCHAR(10))
                                     + N', cpuMs='      + CAST(ISNULL(tp.TotalWorkerTimeMs, 0) AS NVARCHAR(20))
                                     + N'] ' + ISNULL(tp.QueryText, N'(text unavailable)')
                                FROM #PlanOps AS po
                                INNER JOIN #TopPlans AS tp ON tp.RowId = po.RowId
                                WHERE po.TableScanCount > 0 OR po.SpoolCount > 0
                                ORDER BY (po.TableScanCount + po.SpoolCount) DESC, tp.TotalWorkerTimeMs DESC
                                FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 3, N''), N'');

    SET @PctFlagged = CASE WHEN @Analyzed = 0 THEN 0
                           ELSE CAST(@Flagged AS DECIMAL(9,2)) * 100.0 / CAST(@Analyzed AS DECIMAL(9,2))
                      END;

    IF @Analyzed = 0
    BEGIN
        SET @Score   = 1;
        SET @Finding = N'No cached execution plans for user databases were available in the plan cache, so scan/spool quality could not be assessed automatically (the cache may have been cleared recently or the instance may be idle). Execution plans for the critical queries must be captured and reviewed manually.';
    END
    ELSE IF @Flagged = 0
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'All ' + CAST(@Analyzed AS NVARCHAR(10)) + N' of the most CPU-expensive cached execution plans were analysed and none contain a Table Scan or any Spool operator (index scans observed: '
                     + CAST(@TotalIndexScans AS NVARCHAR(10)) + N'). Databases covered: ' + @DbList + N'. This is consistent with critical queries having been reviewed and tuned via execution plans.';
    END
    ELSE IF @PctFlagged <= 20.0
    BEGIN
        SET @Score   = 2;
        SET @Finding = N'Of the ' + CAST(@Analyzed AS NVARCHAR(10)) + N' most CPU-expensive cached execution plans, ' + CAST(@Flagged AS NVARCHAR(10)) + N' ('
                     + CAST(@PctFlagged AS NVARCHAR(10)) + N'%) contain unexpected operators: ' + CAST(@TotalTableScans AS NVARCHAR(10)) + N' Table Scan and '
                     + CAST(@TotalSpools AS NVARCHAR(10)) + N' Spool operator(s) in total. Databases covered: ' + @DbList + N'. Worst offenders: ' + @Sample;
    END
    ELSE IF @PctFlagged <= 50.0
    BEGIN
        SET @Score   = 1;
        SET @Finding = N'Of the ' + CAST(@Analyzed AS NVARCHAR(10)) + N' most CPU-expensive cached execution plans, ' + CAST(@Flagged AS NVARCHAR(10)) + N' ('
                     + CAST(@PctFlagged AS NVARCHAR(10)) + N'%) contain unexpected operators: ' + CAST(@TotalTableScans AS NVARCHAR(10)) + N' Table Scan and '
                     + CAST(@TotalSpools AS NVARCHAR(10)) + N' Spool operator(s) in total. Databases covered: ' + @DbList + N'. Worst offenders: ' + @Sample;
    END
    ELSE
    BEGIN
        SET @Score   = 0;
        SET @Finding = N'Of the ' + CAST(@Analyzed AS NVARCHAR(10)) + N' most CPU-expensive cached execution plans, ' + CAST(@Flagged AS NVARCHAR(10)) + N' ('
                     + CAST(@PctFlagged AS NVARCHAR(10)) + N'%) contain unexpected operators: ' + CAST(@TotalTableScans AS NVARCHAR(10)) + N' Table Scan and '
                     + CAST(@TotalSpools AS NVARCHAR(10)) + N' Spool operator(s) in total. Databases covered: ' + @DbList + N'. Worst offenders: ' + @Sample;
    END;
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;

DROP TABLE #PlanOps;
DROP TABLE #TopPlans;