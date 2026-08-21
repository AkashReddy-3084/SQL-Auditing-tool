/*
    Checklist Item : 14.2.5 - Columnstore health maintained (rowgroup quality, tuple mover) where used
    Scope          : DATABASE (all accessible user databases; current database on Azure SQL Database)
    Type           : Read-only. Uses catalog views only; performs no DDL/DML against user data.
*/
SET NOCOUNT ON;

DECLARE @IsAzureSqlDb BIT = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#CsDb')  IS NOT NULL DROP TABLE #CsDb;
IF OBJECT_ID('tempdb..#CsIdx') IS NOT NULL DROP TABLE #CsIdx;
IF OBJECT_ID('tempdb..#CsErr') IS NOT NULL DROP TABLE #CsErr;

CREATE TABLE #CsDb  (DatabaseName SYSNAME NOT NULL);
CREATE TABLE #CsErr (DatabaseName SYSNAME NOT NULL, ErrorMessage NVARCHAR(2048) NULL);
CREATE TABLE #CsIdx
(
    DatabaseName             SYSNAME       NOT NULL,
    SchemaName               SYSNAME       NOT NULL,
    TableName                SYSNAME       NOT NULL,
    IndexName                SYSNAME       NULL,
    TotalRowGroups           INT           NOT NULL,
    CompressedRowGroups      INT           NOT NULL,
    OpenRowGroups            INT           NOT NULL,
    ClosedRowGroups          INT           NOT NULL,
    SmallCompressedRowGroups INT           NOT NULL,
    TotalRows                BIGINT        NOT NULL,
    DeletedRows              BIGINT        NOT NULL,
    DeletedPct               DECIMAL(9,2)  NOT NULL,
    HealthState              VARCHAR(10)   NULL
);

/* ---------- Build the list of databases to inspect ---------- */
IF @IsAzureSqlDb = 1
BEGIN
    INSERT INTO #CsDb (DatabaseName) VALUES (DB_NAME());
END
ELSE
BEGIN
    INSERT INTO #CsDb (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.name NOT IN (N'master', N'model', N'msdb', N'tempdb')
      AND d.state_desc = N'ONLINE'
      AND d.is_read_only = 0
      AND DATABASEPROPERTYEX(d.name, 'Updateability') = N'READ_WRITE'
      AND HAS_DBACCESS(d.name) = 1;
END

/* ---------- Collect columnstore rowgroup statistics per index ---------- */
DECLARE @db     SYSNAME,
        @prefix NVARCHAR(300),
        @sql    NVARCHAR(MAX);

DECLARE cs_db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #CsDb ORDER BY DatabaseName;

OPEN cs_db_cursor;
FETCH NEXT FROM cs_db_cursor INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    /* Three-part names are built with QUOTENAME on the box product; Azure SQL DB stays in-database. */
    SET @prefix = CASE WHEN @IsAzureSqlDb = 1 THEN N'' ELSE QUOTENAME(@db) + N'.' END;

    SET @sql = N'
        SELECT
            @p_db                                                                   AS DatabaseName,
            s.name                                                                  AS SchemaName,
            t.name                                                                  AS TableName,
            i.name                                                                  AS IndexName,
            COUNT(*)                                                                AS TotalRowGroups,
            SUM(CASE WHEN rg.state_desc = ''COMPRESSED'' THEN 1 ELSE 0 END)         AS CompressedRowGroups,
            SUM(CASE WHEN rg.state_desc = ''OPEN''       THEN 1 ELSE 0 END)         AS OpenRowGroups,
            SUM(CASE WHEN rg.state_desc = ''CLOSED''     THEN 1 ELSE 0 END)         AS ClosedRowGroups,
            SUM(CASE WHEN rg.state_desc = ''COMPRESSED'' AND rg.total_rows < 100000
                     THEN 1 ELSE 0 END)                                             AS SmallCompressedRowGroups,
            SUM(CAST(rg.total_rows   AS BIGINT))                                    AS TotalRows,
            SUM(CAST(rg.deleted_rows AS BIGINT))                                    AS DeletedRows,
            CASE WHEN SUM(CAST(rg.total_rows AS BIGINT)) > 0
                 THEN CAST(100.0 * SUM(CAST(rg.deleted_rows AS BIGINT))
                                 / SUM(CAST(rg.total_rows AS BIGINT)) AS DECIMAL(9,2))
                 ELSE CAST(0 AS DECIMAL(9,2)) END                                   AS DeletedPct
        FROM ' + @prefix + N'sys.column_store_row_groups AS rg
        INNER JOIN ' + @prefix + N'sys.indexes AS i
            ON i.object_id = rg.object_id AND i.index_id = rg.index_id
        INNER JOIN ' + @prefix + N'sys.tables AS t
            ON t.object_id = rg.object_id
        INNER JOIN ' + @prefix + N'sys.schemas AS s
            ON s.schema_id = t.schema_id
        WHERE rg.state_desc <> ''TOMBSTONE''
        GROUP BY s.name, t.name, i.name;';

    BEGIN TRY
        INSERT INTO #CsIdx
        (
            DatabaseName, SchemaName, TableName, IndexName,
            TotalRowGroups, CompressedRowGroups, OpenRowGroups, ClosedRowGroups,
            SmallCompressedRowGroups, TotalRows, DeletedRows, DeletedPct
        )
        EXEC sp_executesql @sql, N'@p_db SYSNAME', @p_db = @db;
    END TRY
    BEGIN CATCH
        INSERT INTO #CsErr (DatabaseName, ErrorMessage) VALUES (@db, LEFT(ERROR_MESSAGE(), 2048));
    END CATCH

    FETCH NEXT FROM cs_db_cursor INTO @db;
END

CLOSE cs_db_cursor;
DEALLOCATE cs_db_cursor;

/* ---------- Classify each columnstore index ---------- */
UPDATE #CsIdx
SET HealthState =
    CASE
        WHEN DeletedPct >= 20.00
          OR ClosedRowGroups >= 5
          OR (CompressedRowGroups >= 2 AND SmallCompressedRowGroups * 2 > CompressedRowGroups AND TotalRows >= 1048576)
            THEN 'CRITICAL'
        WHEN DeletedPct >= 10.00
          OR ClosedRowGroups >= 1
          OR (CompressedRowGroups >= 3 AND SmallCompressedRowGroups >= 2)
            THEN 'WARNING'
        ELSE 'HEALTHY'
    END;

/* ---------- Aggregate and score ---------- */
DECLARE @DbInspected INT = (SELECT COUNT(*) FROM #CsDb),
        @DbFailed    INT = (SELECT COUNT(*) FROM #CsErr),
        @IdxTotal    INT = (SELECT COUNT(*) FROM #CsIdx),
        @IdxCritical INT = (SELECT COUNT(*) FROM #CsIdx WHERE HealthState = 'CRITICAL'),
        @IdxWarning  INT = (SELECT COUNT(*) FROM #CsIdx WHERE HealthState = 'WARNING'),
        @IdxHealthy  INT = (SELECT COUNT(*) FROM #CsIdx WHERE HealthState = 'HEALTHY');

DECLARE @TotalRows   BIGINT = (SELECT ISNULL(SUM(TotalRows), 0)        FROM #CsIdx),
        @DeletedRows BIGINT = (SELECT ISNULL(SUM(DeletedRows), 0)      FROM #CsIdx),
        @ClosedTotal INT    = (SELECT ISNULL(SUM(ClosedRowGroups), 0)  FROM #CsIdx),
        @OpenTotal   INT    = (SELECT ISNULL(SUM(OpenRowGroups), 0)    FROM #CsIdx);

DECLARE @OverallDeletedPct DECIMAL(9,2) =
    CASE WHEN (SELECT ISNULL(SUM(TotalRows), 0) FROM #CsIdx) > 0
         THEN CAST(100.0 * (SELECT ISNULL(SUM(DeletedRows), 0) FROM #CsIdx)
                         / (SELECT ISNULL(SUM(TotalRows), 0) FROM #CsIdx) AS DECIMAL(9,2))
         ELSE CAST(0 AS DECIMAL(9,2)) END;

DECLARE @DbList NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT N', ' + DatabaseName FROM #CsDb ORDER BY DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'None');

DECLARE @Examples NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT TOP (5) N'; ' + DatabaseName + N'.' + SchemaName + N'.' + TableName
                         + N' [' + ISNULL(IndexName, N'<unnamed>') + N'] '
                         + HealthState
                         + N' deleted=' + CAST(DeletedPct AS NVARCHAR(20)) + N'%'
                         + N', open=' + CAST(OpenRowGroups AS NVARCHAR(12))
                         + N', closed=' + CAST(ClosedRowGroups AS NVARCHAR(12))
                         + N', small/compressed=' + CAST(SmallCompressedRowGroups AS NVARCHAR(12))
                         + N'/' + CAST(CompressedRowGroups AS NVARCHAR(12))
                  FROM #CsIdx
                  WHERE HealthState IN ('CRITICAL', 'WARNING')
                  ORDER BY CASE HealthState WHEN 'CRITICAL' THEN 0 ELSE 1 END,
                           DeletedPct DESC, ClosedRowGroups DESC, TableName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'');

DECLARE @ErrList NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT TOP (5) N'; ' + DatabaseName + N': ' + ISNULL(ErrorMessage, N'unknown error')
                  FROM #CsErr ORDER BY DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'');

DECLARE @ErrNote NVARCHAR(MAX) =
    CASE WHEN @DbFailed > 0
         THEN N' Note: ' + CAST(@DbFailed AS NVARCHAR(12))
              + N' database(s) could not be queried: ' + @ErrList + N'.'
         ELSE N'' END;

DECLARE @Result  NVARCHAR(20),
        @Score   INT,
        @Finding NVARCHAR(MAX);

IF @DbInspected = 0
BEGIN
    SET @Score   = 1;
    SET @Finding = N'No user database could be inspected for columnstore objects. '
                 + N'Either the instance hosts only system databases or the audit login lacks access to the user databases, '
                 + N'so columnstore rowgroup quality and tuple-mover health could not be evidenced.' + @ErrNote;
END
ELSE IF @IdxTotal = 0
BEGIN
    SET @Score   = 3;
    SET @Finding = N'No columnstore indexes exist in the ' + CAST(@DbInspected AS NVARCHAR(12))
                 + N' inspected user database(s) (' + @DbList + N'). '
                 + N'The "where used" condition of this control is not met, so no rowgroup quality or tuple-mover backlog can exist.'
                 + @ErrNote;
END
ELSE IF @IdxCritical > 0
BEGIN
    SET @Score   = 1;
    SET @Finding = N'Columnstore health is degraded: ' + CAST(@IdxCritical AS NVARCHAR(12)) + N' of '
                 + CAST(@IdxTotal AS NVARCHAR(12)) + N' columnstore index(es) are CRITICAL ('
                 + CAST(@IdxWarning AS NVARCHAR(12)) + N' WARNING, ' + CAST(@IdxHealthy AS NVARCHAR(12)) + N' healthy). '
                 + N'Overall deleted rows ' + CAST(@OverallDeletedPct AS NVARCHAR(20)) + N'% of '
                 + CAST(@TotalRows AS NVARCHAR(30)) + N' rows; ' + CAST(@ClosedTotal AS NVARCHAR(12))
                 + N' CLOSED and ' + CAST(@OpenTotal AS NVARCHAR(12)) + N' OPEN rowgroup(s) outstanding. Worst offenders: '
                 + @Examples + N'.' + @ErrNote;
END
ELSE IF @IdxWarning > 0
BEGIN
    SET @Score   = 2;
    SET @Finding = N'Columnstore health is broadly acceptable but ' + CAST(@IdxWarning AS NVARCHAR(12)) + N' of '
                 + CAST(@IdxTotal AS NVARCHAR(12)) + N' columnstore index(es) show early degradation and none are critical. '
                 + N'Overall deleted rows ' + CAST(@OverallDeletedPct AS NVARCHAR(20)) + N'% of '
                 + CAST(@TotalRows AS NVARCHAR(30)) + N' rows; ' + CAST(@ClosedTotal AS NVARCHAR(12))
                 + N' CLOSED and ' + CAST(@OpenTotal AS NVARCHAR(12)) + N' OPEN rowgroup(s) outstanding. Affected: '
                 + @Examples + N'.' + @ErrNote;
END
ELSE
BEGIN
    SET @Score   = 3;
    SET @Finding = N'All ' + CAST(@IdxTotal AS NVARCHAR(12)) + N' columnstore index(es) across '
                 + CAST(@DbInspected AS NVARCHAR(12)) + N' user database(s) (' + @DbList + N') are healthy: overall deleted rows '
                 + CAST(@OverallDeletedPct AS NVARCHAR(20)) + N'% of ' + CAST(@TotalRows AS NVARCHAR(30))
                 + N' rows with every index below the 10% threshold, ' + CAST(@ClosedTotal AS NVARCHAR(12))
                 + N' CLOSED rowgroup(s) awaiting the tuple mover, and no pattern of undersized compressed rowgroups.'
                 + @ErrNote;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result  AS Result,
    @Score   AS Score,
    @DbList  AS DatabaseQueried,
    @Finding AS Finding;

IF OBJECT_ID('tempdb..#CsIdx') IS NOT NULL DROP TABLE #CsIdx;
IF OBJECT_ID('tempdb..#CsDb')  IS NOT NULL DROP TABLE #CsDb;
IF OBJECT_ID('tempdb..#CsErr') IS NOT NULL DROP TABLE #CsErr;