/*
    Checklist Item : 4.3.6 - Missing-index recommendations reviewed (not blindly applied)
    Scope          : DATABASE
    Access         : Read-only. Catalog views and DMVs only; no DDL, DML or configuration change
                     against user objects. Staging is done in a local temp table.
    Output         : Result, Score, DatabaseQueried, Finding
*/
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#DbFindings') IS NOT NULL
    DROP TABLE #DbFindings;

CREATE TABLE #DbFindings
(
    DatabaseName SYSNAME NOT NULL,
    UserTables   INT     NOT NULL,
    WideInc      INT     NOT NULL,
    DupLead      INT     NOT NULL,
    UnusedIdx    INT     NOT NULL,
    MissingIdx   INT     NOT NULL,
    HighImpact   INT     NOT NULL,
    DbScore      INT     NULL
);

DECLARE @HasStatePerm     BIT            = 0;
DECLARE @UptimeDays       INT            = NULL;
DECLARE @Db               SYSNAME;
DECLARE @DbId             INT;
DECLARE @Sql              NVARCHAR(MAX);
DECLARE @Params           NVARCHAR(1000);
DECLARE @pUserTables      INT;
DECLARE @pWideInc         INT;
DECLARE @pDupLead         INT;
DECLARE @pUnused          INT;
DECLARE @pMissing         INT;
DECLARE @pHighImpact      INT;
DECLARE @DbCount          INT            = 0;
DECLARE @TotUnused        INT            = 0;
DECLARE @TotDup           INT            = 0;
DECLARE @TotWide          INT            = 0;
DECLARE @TotMissing       INT            = 0;
DECLARE @TotHigh          INT            = 0;
DECLARE @FailDbs          NVARCHAR(1500) = N'';
DECLARE @Score            INT            = 0;
DECLARE @Result           NVARCHAR(20);
DECLARE @DatabaseQueried  NVARCHAR(4000) = N'';
DECLARE @Finding          NVARCHAR(4000) = N'';

/* State-level DMVs are needed for missing-index and index-usage data. */
IF HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE') = 1
   OR HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW DATABASE STATE') = 1
BEGIN
    SET @HasStatePerm = 1;

    SELECT @UptimeDays = DATEDIFF(DAY, si.sqlserver_start_time, GETDATE())
    FROM sys.dm_os_sys_info AS si;
END

SET @Params = N'@pDbId INT, @pUserTables INT OUTPUT, @pWideInc INT OUTPUT, @pDupLead INT OUTPUT, @pUnused INT OUTPUT, @pMissing INT OUTPUT, @pHighImpact INT OUTPUT';

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state_desc = 'ONLINE'
      AND d.source_database_id IS NULL
      AND d.is_in_standby = 0
      AND HAS_DBACCESS(d.name) = 1
    ORDER BY d.name;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @Db;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @DbId        = DB_ID(@Db);
        SET @pUserTables = 0;
        SET @pWideInc    = 0;
        SET @pDupLead    = 0;
        SET @pUnused     = -1;
        SET @pMissing    = -1;
        SET @pHighImpact = -1;

        /* Catalog-only symptoms: verbatim INCLUDE lists and redundant leading-key indexes. */
        SET @Sql = N'
SELECT @pUserTables = COUNT(*)
FROM ' + QUOTENAME(@Db) + N'.sys.tables AS t
WHERE t.is_ms_shipped = 0;

SELECT @pWideInc = ISNULL(SUM(CASE WHEN x.IncludedCols >= 5 THEN 1 ELSE 0 END), 0)
FROM
(
    SELECT
        (
            SELECT COUNT(*)
            FROM ' + QUOTENAME(@Db) + N'.sys.index_columns AS ic
            WHERE ic.object_id = i.object_id
              AND ic.index_id  = i.index_id
              AND ic.is_included_column = 1
        ) AS IncludedCols
    FROM ' + QUOTENAME(@Db) + N'.sys.indexes AS i
    INNER JOIN ' + QUOTENAME(@Db) + N'.sys.tables AS t
        ON t.object_id = i.object_id
       AND t.is_ms_shipped = 0
    WHERE i.type_desc = ''NONCLUSTERED''
      AND i.is_hypothetical = 0
      AND i.is_primary_key = 0
      AND i.is_unique_constraint = 0
) AS x;

SELECT @pDupLead = ISNULL(SUM(d.ExtraIdx), 0)
FROM
(
    SELECT COUNT(*) - 1 AS ExtraIdx
    FROM ' + QUOTENAME(@Db) + N'.sys.indexes AS i
    INNER JOIN ' + QUOTENAME(@Db) + N'.sys.tables AS t
        ON t.object_id = i.object_id
       AND t.is_ms_shipped = 0
    INNER JOIN ' + QUOTENAME(@Db) + N'.sys.index_columns AS ic
        ON ic.object_id = i.object_id
       AND ic.index_id  = i.index_id
       AND ic.key_ordinal = 1
    INNER JOIN ' + QUOTENAME(@Db) + N'.sys.columns AS c
        ON c.object_id = ic.object_id
       AND c.column_id = ic.column_id
    WHERE i.type_desc = ''NONCLUSTERED''
      AND i.is_hypothetical = 0
    GROUP BY i.object_id, c.name
    HAVING COUNT(*) > 1
) AS d;
';

        IF @HasStatePerm = 1
        BEGIN
            /* Strongest symptom: index created but never read, while still paying write cost. */
            SET @Sql = @Sql + N'
SELECT @pUnused = ISNULL(SUM(CASE
                                 WHEN ISNULL(us.user_seeks, 0)
                                    + ISNULL(us.user_scans, 0)
                                    + ISNULL(us.user_lookups, 0) = 0
                                  AND ISNULL(us.user_updates, 0) >= 1000
                                 THEN 1 ELSE 0
                             END), 0)
FROM ' + QUOTENAME(@Db) + N'.sys.indexes AS i
INNER JOIN ' + QUOTENAME(@Db) + N'.sys.tables AS t
    ON t.object_id = i.object_id
   AND t.is_ms_shipped = 0
LEFT JOIN sys.dm_db_index_usage_stats AS us
    ON us.database_id = @pDbId
   AND us.object_id   = i.object_id
   AND us.index_id    = i.index_id
WHERE i.type_desc = ''NONCLUSTERED''
  AND i.is_hypothetical = 0
  AND i.is_unique = 0
  AND i.is_primary_key = 0
  AND i.is_unique_constraint = 0;

SELECT
    @pMissing    = ISNULL(COUNT(*), 0),
    @pHighImpact = ISNULL(SUM(CASE
                                  WHEN gs.avg_user_impact >= 50
                                   AND (gs.user_seeks + gs.user_scans) >= 100
                                  THEN 1 ELSE 0
                              END), 0)
FROM sys.dm_db_missing_index_groups AS g
INNER JOIN sys.dm_db_missing_index_group_stats AS gs
    ON gs.group_handle = g.index_group_handle
INNER JOIN sys.dm_db_missing_index_details AS d
    ON d.index_handle = g.index_handle
WHERE d.database_id = @pDbId;
';
        END

        EXEC sp_executesql @Sql, @Params,
             @pDbId       = @DbId,
             @pUserTables = @pUserTables OUTPUT,
             @pWideInc    = @pWideInc    OUTPUT,
             @pDupLead    = @pDupLead    OUTPUT,
             @pUnused     = @pUnused     OUTPUT,
             @pMissing    = @pMissing    OUTPUT,
             @pHighImpact = @pHighImpact OUTPUT;

        INSERT INTO #DbFindings (DatabaseName, UserTables, WideInc, DupLead, UnusedIdx, MissingIdx, HighImpact, DbScore)
        VALUES (@Db, ISNULL(@pUserTables, 0), ISNULL(@pWideInc, 0), ISNULL(@pDupLead, 0),
                ISNULL(@pUnused, -1), ISNULL(@pMissing, -1), ISNULL(@pHighImpact, -1), NULL);
    END TRY
    BEGIN CATCH
        /* Database not readable by the audit login; leave it out of the evidence set. */
        PRINT 'Skipped database: ' + @Db;
    END CATCH

    FETCH NEXT FROM db_cursor INTO @Db;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

IF NOT EXISTS (SELECT 1 FROM #DbFindings)
BEGIN
    SET @DatabaseQueried = 'None';
    SET @Finding         = 'No database found to be queried';
    SET @Score           = 0;
END
ELSE
BEGIN
    UPDATE #DbFindings
    SET DbScore = CASE
                      WHEN UserTables = 0 THEN 3
                      WHEN UnusedIdx = -1 THEN CASE WHEN DupLead >= 5 THEN 1 ELSE 2 END
                      WHEN UnusedIdx >= 5
                        OR DupLead >= 5
                        OR (WideInc >= 5 AND UnusedIdx >= 1) THEN 1
                      WHEN UnusedIdx >= 1
                        OR DupLead >= 1
                        OR WideInc >= 5
                        OR HighImpact >= 10 THEN 2
                      ELSE 3
                  END;

    /* Usage counters reset on restart; a short evidence window cannot carry a Score 1. */
    IF @UptimeDays IS NOT NULL AND @UptimeDays < 7
    BEGIN
        UPDATE #DbFindings
        SET DbScore = 2
        WHERE DbScore = 1;
    END

    SELECT
        @DbCount    = COUNT(*),
        @TotUnused  = SUM(CASE WHEN UnusedIdx  > 0 THEN UnusedIdx  ELSE 0 END),
        @TotDup     = SUM(CASE WHEN DupLead    > 0 THEN DupLead    ELSE 0 END),
        @TotWide    = SUM(CASE WHEN WideInc    > 0 THEN WideInc    ELSE 0 END),
        @TotMissing = SUM(CASE WHEN MissingIdx > 0 THEN MissingIdx ELSE 0 END),
        @TotHigh    = SUM(CASE WHEN HighImpact > 0 THEN HighImpact ELSE 0 END),
        @Score      = MIN(DbScore)
    FROM #DbFindings;

    SELECT @DatabaseQueried = LEFT(STUFF((
        SELECT N', ' + f.DatabaseName
        FROM #DbFindings AS f
        ORDER BY f.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), 4000);

    SELECT @FailDbs = LEFT(ISNULL(STUFF((
        SELECT N', ' + f.DatabaseName
        FROM #DbFindings AS f
        WHERE f.DbScore <= 2
        ORDER BY f.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'none'), 1500);

    SET @Finding = N'Evaluated ' + CAST(@DbCount AS NVARCHAR(10)) + N' user database(s). Aggregate symptoms of unreviewed index creation: '
                 + CAST(@TotUnused AS NVARCHAR(10)) + N' nonclustered index(es) never read but carrying 1000+ updates, '
                 + CAST(@TotDup AS NVARCHAR(10)) + N' redundant index(es) sharing a leading key column, '
                 + CAST(@TotWide AS NVARCHAR(10)) + N' index(es) with 5 or more INCLUDE columns. Outstanding missing-index recommendations: '
                 + CAST(@TotMissing AS NVARCHAR(10)) + N' total, ' + CAST(@TotHigh AS NVARCHAR(10)) + N' high-impact. Index usage statistics cover '
                 + ISNULL(CAST(@UptimeDays AS NVARCHAR(10)), N'an unknown number of') + N' day(s) of instance uptime. Database(s) below the target: ' + @FailDbs + N'. '
                 + CASE
                       WHEN @HasStatePerm = 0
                           THEN N'VIEW SERVER STATE / VIEW DATABASE STATE is not granted to the audit login, so index usage and missing-index DMVs could not be read; only catalog evidence was available and manual review is required.'
                       WHEN @Score = 3
                           THEN N'No symptoms of blindly applied recommendations were detected; missing-index recommendations appear to be triaged before implementation.'
                       WHEN @Score = 2
                           THEN N'Limited symptoms of unreviewed index creation were detected, or the evidence window is too short to conclude; review the indexes above against the current workload.'
                       ELSE N'Multiple indexes are never read yet are maintained on every write, and/or many redundant leading-key indexes exist - a strong indicator that DMV recommendations were applied without review.'
                   END;

    SET @Finding = LEFT(@Finding, 4000);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#DbFindings') IS NOT NULL
    DROP TABLE #DbFindings;