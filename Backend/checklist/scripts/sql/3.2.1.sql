/* =====================================================================
   Checklist Item : 3.2.1
   Description    : Business/transformation logic encapsulated in stored
                    procedures/functions (not ad-hoc scripts)
   Scope          : DATABASE  (every qualifying user database is scored)
   Mode           : READ-ONLY (catalog views and DMVs; temp tables only)
   Output         : Result, Score, DatabaseQueried, Finding
   ===================================================================== */
SET NOCOUNT ON;

CREATE TABLE #DbMetrics
(
    DbName     sysname NOT NULL,
    DbId       int     NOT NULL,
    ProcCount  int     NOT NULL,
    FuncCount  int     NOT NULL,
    TableCount int     NOT NULL,
    ViewCount  int     NOT NULL
);

CREATE TABLE #PlanMix
(
    DbId        int NOT NULL,
    AdhocPlans  int NOT NULL,
    ModulePlans int NOT NULL
);

CREATE TABLE #DbScored
(
    DbName          sysname      NOT NULL,
    ProcCount       int          NOT NULL,
    FuncCount       int          NOT NULL,
    TableCount      int          NOT NULL,
    ViewCount       int          NOT NULL,
    AdhocPlans      int          NOT NULL,
    ModulePlans     int          NOT NULL,
    HasPlanEvidence bit          NOT NULL,
    AdhocPct        decimal(5,2) NULL,
    DbScore         int          NOT NULL
);

DECLARE @IsAzureDb       bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;
DECLARE @DbName          sysname;
DECLARE @DbId            int;
DECLARE @Sql             nvarchar(max);
DECLARE @DatabaseQueried nvarchar(4000) = NULL;
DECLARE @WorstList       nvarchar(2000) = NULL;
DECLARE @Result          nvarchar(20);
DECLARE @Score           int;
DECLARE @Finding         nvarchar(4000);
DECLARE @DbCount         int = 0;
DECLARE @NoModuleCount   int = 0;
DECLARE @AdhocHeavyCount int = 0;
DECLARE @UnverifiedCount int = 0;
DECLARE @CompliantCount  int = 0;

/* ---------------------------------------------------------------
   Execution evidence: server-wide plan cache grouped per database.
   Needs VIEW SERVER STATE / VIEW DATABASE STATE; without it the
   inventory still scores and the mix is reported as unverified.
   --------------------------------------------------------------- */
BEGIN TRY
    INSERT INTO #PlanMix (DbId, AdhocPlans, ModulePlans)
    SELECT
        st.dbid,
        SUM(CASE WHEN cp.objtype IN ('Adhoc', 'Prepared') THEN 1 ELSE 0 END),
        SUM(CASE WHEN cp.objtype IN ('Proc', 'Trigger')   THEN 1 ELSE 0 END)
    FROM sys.dm_exec_cached_plans AS cp
    CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) AS st
    WHERE st.dbid IS NOT NULL
    GROUP BY st.dbid;
END TRY
BEGIN CATCH
    /* Plan cache not readable by this principal - inventory only. */
END CATCH

/* ---------------------------------------------------------------
   Inventory every qualifying user database.
   --------------------------------------------------------------- */
IF @IsAzureDb = 1
BEGIN
    /* Azure SQL Database forbids cross-database queries, so only the
       connected database can be inventoried. */
    IF DB_ID() > 4
    BEGIN
        INSERT INTO #DbMetrics (DbName, DbId, ProcCount, FuncCount, TableCount, ViewCount)
        SELECT
            DB_NAME(),
            DB_ID(),
            (SELECT COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0),
            (SELECT COUNT(*) FROM sys.objects
              WHERE type IN ('FN', 'IF', 'TF', 'AF', 'FS', 'FT') AND is_ms_shipped = 0),
            (SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0),
            (SELECT COUNT(*) FROM sys.views  WHERE is_ms_shipped = 0);
    END
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name, d.database_id
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state_desc = 'ONLINE'
          AND d.is_in_standby = 0
          AND d.source_database_id IS NULL
          AND d.name NOT IN (N'distribution', N'SSISDB', N'ReportServer',
                             N'ReportServerTempDB', N'SSISDB_Catalog')
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName, @DbId;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql =
                N'INSERT INTO #DbMetrics (DbName, DbId, ProcCount, FuncCount, TableCount, ViewCount)' + CHAR(13) +
                N'SELECT @p_name, @p_id,' + CHAR(13) +
                N'    (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.procedures WHERE is_ms_shipped = 0),' + CHAR(13) +
                N'    (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.objects' + CHAR(13) +
                N'      WHERE type IN (''FN'', ''IF'', ''TF'', ''AF'', ''FS'', ''FT'') AND is_ms_shipped = 0),' + CHAR(13) +
                N'    (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.tables WHERE is_ms_shipped = 0),' + CHAR(13) +
                N'    (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.views  WHERE is_ms_shipped = 0);';

            EXEC sys.sp_executesql @Sql,
                 N'@p_name sysname, @p_id int',
                 @p_name = @DbName,
                 @p_id   = @DbId;
        END TRY
        BEGIN CATCH
            /* Database not readable by this principal - skipped. */
        END CATCH

        FETCH NEXT FROM db_cursor INTO @DbName, @DbId;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

/* ---------------------------------------------------------------
   Deterministic per-database scoring
   --------------------------------------------------------------- */
INSERT INTO #DbScored
    (DbName, ProcCount, FuncCount, TableCount, ViewCount,
     AdhocPlans, ModulePlans, HasPlanEvidence, AdhocPct, DbScore)
SELECT
    m.DbName,
    m.ProcCount,
    m.FuncCount,
    m.TableCount,
    m.ViewCount,
    ISNULL(p.AdhocPlans, 0),
    ISNULL(p.ModulePlans, 0),
    CASE WHEN ISNULL(p.AdhocPlans, 0) + ISNULL(p.ModulePlans, 0) > 0 THEN 1 ELSE 0 END,
    CASE WHEN ISNULL(p.AdhocPlans, 0) + ISNULL(p.ModulePlans, 0) > 0
         THEN CAST(100.0 * ISNULL(p.AdhocPlans, 0)
                   / (ISNULL(p.AdhocPlans, 0) + ISNULL(p.ModulePlans, 0)) AS decimal(5,2))
         END,
    CASE
        WHEN m.TableCount = 0 AND m.ViewCount = 0 AND (m.ProcCount + m.FuncCount) = 0 THEN 3
        WHEN (m.ProcCount + m.FuncCount) = 0                                          THEN 0
        WHEN m.TableCount > 0 AND (m.ProcCount + m.FuncCount) * 5 < m.TableCount      THEN 1
        WHEN ISNULL(p.AdhocPlans, 0) + ISNULL(p.ModulePlans, 0) = 0                   THEN 2
        WHEN 100.0 * ISNULL(p.AdhocPlans, 0)
             / (ISNULL(p.AdhocPlans, 0) + ISNULL(p.ModulePlans, 0)) <= 25.0           THEN 3
        WHEN 100.0 * ISNULL(p.AdhocPlans, 0)
             / (ISNULL(p.AdhocPlans, 0) + ISNULL(p.ModulePlans, 0)) <= 60.0           THEN 2
        ELSE 1
    END
FROM #DbMetrics AS m
LEFT JOIN #PlanMix AS p ON p.DbId = m.DbId;

/* ---------------------------------------------------------------
   Aggregate to the single audit row
   --------------------------------------------------------------- */
SELECT @DbCount = COUNT(*) FROM #DbScored;

IF @DbCount = 0
BEGIN
    SET @DatabaseQueried = N'None';
    SET @Finding         = N'No database found to be queried';
    SET @Score           = 0;
END
ELSE
BEGIN
    SELECT @Score = MIN(DbScore) FROM #DbScored;

    SELECT @NoModuleCount   = SUM(CASE WHEN (ProcCount + FuncCount) = 0 AND (TableCount + ViewCount) > 0 THEN 1 ELSE 0 END),
           @AdhocHeavyCount = SUM(CASE WHEN (ProcCount + FuncCount) > 0 AND DbScore = 1 THEN 1 ELSE 0 END),
           @UnverifiedCount = SUM(CASE WHEN (ProcCount + FuncCount) > 0 AND HasPlanEvidence = 0 THEN 1 ELSE 0 END),
           @CompliantCount  = SUM(CASE WHEN DbScore = 3 THEN 1 ELSE 0 END)
    FROM #DbScored;

    SELECT @DatabaseQueried = ISNULL(@DatabaseQueried + N', ', N'') + DbName
    FROM #DbScored;

    SELECT @WorstList = ISNULL(@WorstList + N'; ', N'')
                      + DbName + N' (' + CAST(ProcCount AS nvarchar(20)) + N' proc(s), '
                      + CAST(FuncCount AS nvarchar(20)) + N' function(s), '
                      + CAST(TableCount AS nvarchar(20)) + N' table(s), '
                      + CASE WHEN HasPlanEvidence = 1
                             THEN CAST(AdhocPct AS nvarchar(20)) + N'% ad-hoc plans'
                             ELSE N'plan mix unverified' END + N')'
    FROM #DbScored
    WHERE DbScore = @Score;

    SET @Finding = N'Evaluated ' + CAST(@DbCount AS nvarchar(20)) + N' user database(s). '
                 + CAST(ISNULL(@NoModuleCount, 0) AS nvarchar(20))
                 + N' database(s) hold user tables or views but contain no stored procedures and no '
                 + N'functions, so all business/transformation logic against them must be issued as '
                 + N'ad-hoc T-SQL. '
                 + CAST(ISNULL(@AdhocHeavyCount, 0) AS nvarchar(20))
                 + N' database(s) have a programmable layer that is largely bypassed or far too thin '
                 + N'for the schema it covers. '
                 + CAST(ISNULL(@UnverifiedCount, 0) AS nvarchar(20))
                 + N' database(s) have modules but no plan-cache evidence, so their actual ad-hoc '
                 + N'versus procedural execution mix is unverified. '
                 + CAST(ISNULL(@CompliantCount, 0) AS nvarchar(20))
                 + N' database(s) execute their workload predominantly through encapsulated modules. '
                 + N'Lowest scoring database(s): ' + ISNULL(@WorstList, N'n/a') + N'.';

    IF LEN(@DatabaseQueried) > 3900
        SET @DatabaseQueried = LEFT(@DatabaseQueried, 3897) + N'...';
END

SET @Result = CASE WHEN @Score >= 3 THEN N'Pass'
                   WHEN @Score <= 0 THEN N'Fail'
                   ELSE N'Partial' END;

SELECT
    CAST(@Result AS nvarchar(20))            AS Result,
    CAST(@Score AS int)                      AS Score,
    CAST(@DatabaseQueried AS nvarchar(4000)) AS DatabaseQueried,
    CAST(@Finding AS nvarchar(4000))         AS Finding;