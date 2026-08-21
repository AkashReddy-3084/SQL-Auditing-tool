/* Checklist 5.3.4 - Aggregate consistency: detail sums equal aggregate totals
   Read-only. Deterministic proxy: locates aggregate/summary structures and the
   engine- or code-based controls that keep them tied to their detail rows. */
SET NOCOUNT ON;

DECLARE @Result           NVARCHAR(20);
DECLARE @Score            INT;
DECLARE @DatabaseQueried  NVARCHAR(MAX);
DECLARE @Finding          NVARCHAR(MAX);

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

CREATE TABLE #AggScan
(
    DatabaseName      SYSNAME NOT NULL,
    AggregateTables   INT     NOT NULL,
    IndexedAggViews   INT     NOT NULL,
    ReconObjects      INT     NOT NULL,
    AggMaintTriggers  INT     NOT NULL
);

DECLARE @Template NVARCHAR(MAX) = N'
INSERT INTO #AggScan (DatabaseName, AggregateTables, IndexedAggViews, ReconObjects, AggMaintTriggers)
SELECT
    @db,
    (SELECT COUNT(*)
       FROM {DB}.sys.tables AS t
      WHERE t.is_ms_shipped = 0
        AND (   t.name LIKE ''%summary%''   OR t.name LIKE ''%aggregat%''
             OR t.name LIKE ''%agg[_]%''    OR t.name LIKE ''%[_]agg''
             OR t.name LIKE ''%rollup%''    OR t.name LIKE ''%roll[_]up%''
             OR t.name LIKE ''%total%''     OR t.name LIKE ''%subtotal%''
             OR t.name LIKE ''fact[_]%''    OR t.name LIKE ''%[_]fact''
             OR t.name LIKE ''%snapshot%'' )),
    (SELECT COUNT(*)
       FROM {DB}.sys.views AS v
       JOIN {DB}.sys.indexes AS i
         ON i.object_id = v.object_id AND i.index_id = 1
       JOIN {DB}.sys.sql_modules AS m
         ON m.object_id = v.object_id
      WHERE v.is_ms_shipped = 0
        AND (m.definition LIKE ''%COUNT_BIG%'' OR m.definition LIKE ''%SUM(%'')),
    (SELECT COUNT(*)
       FROM {DB}.sys.objects AS o
       LEFT JOIN {DB}.sys.sql_modules AS sm
         ON sm.object_id = o.object_id
      WHERE o.is_ms_shipped = 0
        AND o.type IN (''P'',''FN'',''IF'',''TF'',''V'')
        AND (   o.name LIKE ''%reconcil%''        OR o.name LIKE ''%recon[_]%''
             OR o.name LIKE ''%[_]recon%''        OR o.name LIKE ''%tieout%''
             OR o.name LIKE ''%tie[_]out%''       OR o.name LIKE ''%variance%''
             OR o.name LIKE ''%checktotal%''      OR o.name LIKE ''%check[_]total%''
             OR o.name LIKE ''%validate%total%''  OR o.name LIKE ''%verify%total%''
             OR (    sm.definition LIKE ''%SUM(%''
                 AND (   sm.definition LIKE ''%reconcil%''  OR sm.definition LIKE ''%variance%''
                      OR sm.definition LIKE ''%mismatch%''  OR sm.definition LIKE ''%discrepan%'' )))),
    (SELECT COUNT(*)
       FROM {DB}.sys.triggers AS tr
       JOIN {DB}.sys.tables AS t2
         ON t2.object_id = tr.parent_id
       JOIN {DB}.sys.sql_modules AS tm
         ON tm.object_id = tr.object_id
      WHERE tr.is_ms_shipped = 0
        AND tr.is_disabled = 0
        AND (tm.definition LIKE ''%SUM(%'' OR tm.definition LIKE ''%COUNT(%''));';

DECLARE @DbName SYSNAME, @Sql NVARCHAR(MAX);

IF @EngineEdition = 5
BEGIN
    /* Azure SQL Database: only the current database is reachable. */
    SET @DbName = DB_NAME();
    SET @Sql = REPLACE(@Template, N'{DB}', QUOTENAME(@DbName));
    BEGIN TRY
        EXEC sp_executesql @Sql, N'@db SYSNAME', @db = @DbName;
    END TRY
    BEGIN CATCH
        /* database not inspectable - left out of the population */
    END CATCH
END
ELSE
BEGIN
    DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
          FROM sys.databases AS d
         WHERE d.database_id > 4
           AND d.state = 0
           AND d.source_database_id IS NULL
           AND d.is_read_only = 0
           AND HAS_DBACCESS(d.name) = 1
         ORDER BY d.name;

    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @DbName;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Sql = REPLACE(@Template, N'{DB}', QUOTENAME(@DbName));
        BEGIN TRY
            EXEC sp_executesql @Sql, N'@db SYSNAME', @db = @DbName;
        END TRY
        BEGIN CATCH
            /* database not inspectable - left out of the population */
        END CATCH
        FETCH NEXT FROM db_cur INTO @DbName;
    END
    CLOSE db_cur;
    DEALLOCATE db_cur;
END

DECLARE @DbCount      INT = (SELECT COUNT(*) FROM #AggScan);
DECLARE @WithAgg      INT = (SELECT COUNT(*) FROM #AggScan
                              WHERE AggregateTables > 0 OR IndexedAggViews > 0);
DECLARE @Uncontrolled INT = (SELECT COUNT(*) FROM #AggScan
                              WHERE (AggregateTables > 0 OR IndexedAggViews > 0)
                                AND IndexedAggViews = 0
                                AND ReconObjects = 0
                                AND AggMaintTriggers = 0);
DECLARE @Controlled   INT = @WithAgg - @Uncontrolled;

DECLARE @BadList NVARCHAR(MAX) =
    STUFF((SELECT N', ' + s.DatabaseName
             FROM #AggScan AS s
            WHERE (s.AggregateTables > 0 OR s.IndexedAggViews > 0)
              AND s.IndexedAggViews = 0
              AND s.ReconObjects = 0
              AND s.AggMaintTriggers = 0
            ORDER BY s.DatabaseName
              FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @TotAggTables INT = (SELECT ISNULL(SUM(AggregateTables), 0) FROM #AggScan);
DECLARE @TotAggViews  INT = (SELECT ISNULL(SUM(IndexedAggViews), 0) FROM #AggScan);
DECLARE @TotRecon     INT = (SELECT ISNULL(SUM(ReconObjects), 0) FROM #AggScan);
DECLARE @TotTriggers  INT = (SELECT ISNULL(SUM(AggMaintTriggers), 0) FROM #AggScan);

SET @DatabaseQueried =
    ISNULL(STUFF((SELECT N', ' + s.DatabaseName
                    FROM #AggScan AS s
                   ORDER BY s.DatabaseName
                     FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'None');

SET @Score = CASE
                 WHEN @DbCount = 0 THEN 0
                 WHEN @Uncontrolled = 0 THEN 3
                 WHEN @Controlled > 0 THEN 1
                 ELSE 0
             END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding = CASE
    WHEN @DbCount = 0
        THEN N'No accessible user database could be inspected, so no evidence of detail-to-aggregate consistency enforcement could be collected.'
    WHEN @WithAgg = 0
        THEN N'Scanned ' + CAST(@DbCount AS NVARCHAR(10))
             + N' user database(s); no aggregate/summary structures were detected (0 summary-style tables, 0 indexed aggregate views), so there is no detail-to-aggregate reconciliation exposure.'
    WHEN @Uncontrolled = 0
        THEN N'Scanned ' + CAST(@DbCount AS NVARCHAR(10)) + N' user database(s). All '
             + CAST(@WithAgg AS NVARCHAR(10))
             + N' database(s) holding aggregate structures also expose at least one consistency control. Totals: '
             + CAST(@TotAggTables AS NVARCHAR(10)) + N' summary-style table(s), '
             + CAST(@TotAggViews AS NVARCHAR(10)) + N' engine-maintained indexed aggregate view(s), '
             + CAST(@TotRecon AS NVARCHAR(10)) + N' reconciliation/tie-out module(s), '
             + CAST(@TotTriggers AS NVARCHAR(10)) + N' aggregate-maintaining trigger(s).'
    WHEN @Controlled > 0
        THEN N'Scanned ' + CAST(@DbCount AS NVARCHAR(10)) + N' user database(s). '
             + CAST(@Controlled AS NVARCHAR(10)) + N' of ' + CAST(@WithAgg AS NVARCHAR(10))
             + N' database(s) with aggregate structures have a consistency control, but '
             + CAST(@Uncontrolled AS NVARCHAR(10))
             + N' do not: ' + ISNULL(@BadList, N'') + N'. Totals: '
             + CAST(@TotAggTables AS NVARCHAR(10)) + N' summary-style table(s), '
             + CAST(@TotAggViews AS NVARCHAR(10)) + N' indexed aggregate view(s), '
             + CAST(@TotRecon AS NVARCHAR(10)) + N' reconciliation/tie-out module(s), '
             + CAST(@TotTriggers AS NVARCHAR(10)) + N' aggregate-maintaining trigger(s).'
    ELSE N'Scanned ' + CAST(@DbCount AS NVARCHAR(10)) + N' user database(s). '
         + CAST(@WithAgg AS NVARCHAR(10))
         + N' database(s) hold aggregate/summary structures (' + CAST(@TotAggTables AS NVARCHAR(10))
         + N' summary-style table(s)) but none expose any consistency control: 0 engine-maintained indexed aggregate views, 0 reconciliation/tie-out modules, 0 aggregate-maintaining triggers. Affected: '
         + ISNULL(@BadList, N'') + N'.'
END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

DROP TABLE #AggScan;