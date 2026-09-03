/* Checklist 14.1.4 - Implicit conversions eliminated (data-type mismatches in joins/filters)
   Read-only. Inspects cached showplan XML for PlanAffectingConvert warnings, which SQL Server
   raises whenever a CONVERT_IMPLICIT in a join or filter degrades a seek or a cardinality estimate.
   Compatible with SQL Server 2016+ (instance-wide) and Azure SQL Database (current database). */
SET NOCOUNT ON;

DECLARE @Result           NVARCHAR(20);
DECLARE @Score            INT            = 0;
DECLARE @DatabaseQueried  NVARCHAR(256);
DECLARE @Finding          NVARCHAR(MAX)  = N'';
DECLARE @EngineEdition    INT            = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @ScannedPlans     INT            = 0;
DECLARE @AffectedPlans    INT            = 0;
DECLARE @SeekPlanIssues   INT            = 0;
DECLARE @TotalConverts    INT            = 0;
DECLARE @PctAffected      DECIMAL(9,2)   = 0.00;
DECLARE @TopOffenders     NVARCHAR(MAX)  = N'';
DECLARE @ErrMsg           NVARCHAR(400)  = NULL;

SET @DatabaseQueried = CASE WHEN @EngineEdition = 5 THEN DB_NAME() ELSE N'SERVER' END;

IF OBJECT_ID('tempdb..#CachedPlanHandles') IS NOT NULL DROP TABLE #CachedPlanHandles;
IF OBJECT_ID('tempdb..#ImplicitConversions') IS NOT NULL DROP TABLE #ImplicitConversions;
IF OBJECT_ID('tempdb..#TopOffenders') IS NOT NULL DROP TABLE #TopOffenders;

CREATE TABLE #CachedPlanHandles
(
    PlanHandle VARBINARY(64) NOT NULL,
    UseCounts  INT           NOT NULL
);

CREATE TABLE #ImplicitConversions
(
    DatabaseName     NVARCHAR(256) NULL,
    ObjectName       NVARCHAR(512) NULL,
    ConvertCount     INT           NULL,
    SeekPlanCount    INT           NULL,
    UseCounts        INT           NULL,
    StatementSnippet NVARCHAR(300) NULL
);

CREATE TABLE #TopOffenders
(
    RowNo INT            NOT NULL,
    Descr NVARCHAR(1000) NOT NULL
);

BEGIN TRY
    INSERT INTO #CachedPlanHandles (PlanHandle, UseCounts)
    SELECT TOP (2000) cp.plan_handle, cp.usecounts
    FROM sys.dm_exec_cached_plans AS cp
    WHERE cp.cacheobjtype = N'Compiled Plan'
      AND cp.objtype IN (N'Adhoc', N'Prepared', N'Proc')
    ORDER BY cp.usecounts DESC;

    SET @ScannedPlans = @@ROWCOUNT;

    IF @ScannedPlans > 0
    BEGIN
        INSERT INTO #ImplicitConversions
            (DatabaseName, ObjectName, ConvertCount, SeekPlanCount, UseCounts, StatementSnippet)
        SELECT COALESCE(DB_NAME(st.dbid), N'(unknown)'),
               COALESCE(OBJECT_SCHEMA_NAME(st.objectid, st.dbid) + N'.' + OBJECT_NAME(st.objectid, st.dbid), N'(ad hoc batch)'),
               qp.query_plan.value('count(//*:PlanAffectingConvert)', 'int'),
               qp.query_plan.value('count(//*:PlanAffectingConvert[@ConvertIssue="Seek Plan"])', 'int'),
               h.UseCounts,
               LEFT(LTRIM(REPLACE(REPLACE(REPLACE(ISNULL(st.text, N''), CHAR(13), N' '), CHAR(10), N' '), CHAR(9), N' ')), 300)
        FROM #CachedPlanHandles AS h
        CROSS APPLY sys.dm_exec_query_plan(h.PlanHandle) AS qp
        OUTER APPLY sys.dm_exec_sql_text(h.PlanHandle) AS st
        WHERE qp.query_plan IS NOT NULL
          AND qp.query_plan.exist('//*:PlanAffectingConvert') = 1;

        SELECT @AffectedPlans  = COUNT(*),
               @TotalConverts  = ISNULL(SUM(ic.ConvertCount), 0),
               @SeekPlanIssues = ISNULL(SUM(ic.SeekPlanCount), 0)
        FROM #ImplicitConversions AS ic;

        INSERT INTO #TopOffenders (RowNo, Descr)
        SELECT TOP (5)
               ROW_NUMBER() OVER (ORDER BY ic.SeekPlanCount DESC, ic.ConvertCount DESC, ic.UseCounts DESC),
               N'[' + ic.DatabaseName + N'] ' + ic.ObjectName
                   + N' (converts=' + CONVERT(NVARCHAR(20), ic.ConvertCount)
                   + N', seekPlan=' + CONVERT(NVARCHAR(20), ic.SeekPlanCount)
                   + N', uses='     + CONVERT(NVARCHAR(20), ic.UseCounts)
                   + N', sql="' + LEFT(ic.StatementSnippet, 120) + N'"); '
        FROM #ImplicitConversions AS ic
        ORDER BY ic.SeekPlanCount DESC, ic.ConvertCount DESC, ic.UseCounts DESC;

        SELECT @TopOffenders = @TopOffenders + t.Descr
        FROM #TopOffenders AS t
        ORDER BY t.RowNo;
    END
END TRY
BEGIN CATCH
    SET @ErrMsg = LEFT(ERROR_MESSAGE(), 400);
END CATCH

IF @ErrMsg IS NOT NULL
BEGIN
    SET @Score = 0;
    SET @Finding = N'Implicit-conversion check could not be completed - manual review required. Error: ' + @ErrMsg
                 + N' Reading sys.dm_exec_cached_plans / sys.dm_exec_query_plan requires VIEW SERVER STATE (VIEW DATABASE STATE on Azure SQL Database).';
END
ELSE IF @ScannedPlans = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'The plan cache contains no compiled plans, so implicit conversions could not be assessed - manual review required. This normally follows an instance restart, a failover or a recent DBCC FREEPROCCACHE. Re-run the check after a representative workload period.';
END
ELSE
BEGIN
    SET @PctAffected = CONVERT(DECIMAL(9,2), (@AffectedPlans * 100.0) / @ScannedPlans);

    IF @AffectedPlans = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = N'No implicit conversions detected. ' + CONVERT(NVARCHAR(20), @ScannedPlans)
                     + N' cached compiled plans were inspected and none contained a PlanAffectingConvert warning, indicating join and filter predicates are type-aligned with their columns.';
    END
    ELSE IF @SeekPlanIssues = 0 AND @PctAffected <= 5.00
    BEGIN
        SET @Score = 2;
        SET @Finding = N'Largely compliant: ' + CONVERT(NVARCHAR(20), @AffectedPlans) + N' of ' + CONVERT(NVARCHAR(20), @ScannedPlans)
                     + N' cached plans (' + CONVERT(NVARCHAR(20), @PctAffected) + N'%) carry ' + CONVERT(NVARCHAR(20), @TotalConverts)
                     + N' implicit-conversion warning(s), but none are "Seek Plan" conversions - index seeks are still being used and only cardinality estimates are affected. Top offenders: '
                     + LEFT(@TopOffenders, 1200);
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Finding = N'Implicit conversions are present: ' + CONVERT(NVARCHAR(20), @AffectedPlans) + N' of ' + CONVERT(NVARCHAR(20), @ScannedPlans)
                     + N' cached plans (' + CONVERT(NVARCHAR(20), @PctAffected) + N'%) contain ' + CONVERT(NVARCHAR(20), @TotalConverts)
                     + N' PlanAffectingConvert warning(s), of which ' + CONVERT(NVARCHAR(20), @SeekPlanIssues)
                     + N' are "Seek Plan" conversions that prevent index seeks. Top offenders: ' + LEFT(@TopOffenders, 1200);
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;