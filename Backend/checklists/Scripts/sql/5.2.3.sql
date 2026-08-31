SET NOCOUNT ON;

/* Checklist 5.2.3 - Record count reconciliation vs. source control counts. Read-only. */

DECLARE @IsAzureDb bit = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

DECLARE @Result           nvarchar(30);
DECLARE @Score            int;
DECLARE @DatabaseQueried  nvarchar(max);
DECLARE @Finding          nvarchar(max);

IF OBJECT_ID('tempdb..#Db') IS NOT NULL DROP TABLE #Db;
IF OBJECT_ID('tempdb..#Err') IS NOT NULL DROP TABLE #Err;
IF OBJECT_ID('tempdb..#ReconObj') IS NOT NULL DROP TABLE #ReconObj;
IF OBJECT_ID('tempdb..#DbScore') IS NOT NULL DROP TABLE #DbScore;

CREATE TABLE #Db (DatabaseName sysname NOT NULL PRIMARY KEY);
CREATE TABLE #Err (DatabaseName sysname NOT NULL PRIMARY KEY, ErrMsg nvarchar(400) NULL);
CREATE TABLE #ReconObj (
    DatabaseName   sysname       NOT NULL,
    ObjectType     varchar(10)   NOT NULL,
    ObjectName     nvarchar(300) NOT NULL,
    HasSourceCount bit           NOT NULL,
    HasTargetCount bit           NOT NULL,
    ApproxRows     bigint        NOT NULL
);
CREATE TABLE #DbScore (
    DatabaseName   sysname NOT NULL PRIMARY KEY,
    ReconTables    int     NOT NULL,
    Pairs          int     NOT NULL,
    PopulatedPairs int     NOT NULL,
    Modules        int     NOT NULL,
    DbScore        int     NOT NULL
);

IF @IsAzureDb = 1
BEGIN
    INSERT INTO #Db (DatabaseName)
    SELECT DB_NAME()
    WHERE DB_NAME() <> N'master';
END
ELSE
BEGIN
    INSERT INTO #Db (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @DbName sysname, @sql nvarchar(max), @ErrMsg nvarchar(400);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Db ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        /* Reconciliation / row-count control tables and their count columns */
        SET @sql = N'
INSERT INTO #ReconObj (DatabaseName, ObjectType, ObjectName, HasSourceCount, HasTargetCount, ApproxRows)
SELECT @DbNameParam, ''TABLE'', s.name + N''.'' + t.name,
       MAX(CASE WHEN c.name LIKE ''%source%count%'' OR c.name LIKE ''%src%count%''
                  OR c.name LIKE ''%source%row%''   OR c.name LIKE ''%source%rec%''
                THEN 1 ELSE 0 END),
       MAX(CASE WHEN c.name LIKE ''%target%count%'' OR c.name LIKE ''%tgt%count%''
                  OR c.name LIKE ''%dest%count%''   OR c.name LIKE ''%load%count%''
                  OR c.name LIKE ''%row%count%''    OR c.name LIKE ''%record%count%''
                THEN 1 ELSE 0 END),
       ISNULL(MAX(ps.RowCnt), 0)
FROM ' + QUOTENAME(@DbName) + N'.sys.tables AS t
INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas AS s ON s.schema_id = t.schema_id
INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.columns AS c ON c.object_id = t.object_id
OUTER APPLY (
    SELECT SUM(p.row_count) AS RowCnt
    FROM ' + QUOTENAME(@DbName) + N'.sys.dm_db_partition_stats AS p
    WHERE p.object_id = t.object_id AND p.index_id IN (0, 1)
) AS ps
WHERE t.is_ms_shipped = 0
  AND ( t.name LIKE ''%recon%''
     OR t.name LIKE ''%row%count%''
     OR t.name LIKE ''%record%count%''
     OR t.name LIKE ''%count%control%''
     OR t.name LIKE ''%control%count%''
     OR t.name LIKE ''%load%control%''
     OR t.name LIKE ''%batch%control%''
     OR t.name LIKE ''%etl%audit%''
     OR t.name LIKE ''%etl%log%''
     OR t.name LIKE ''%audit%balance%''
     OR t.name LIKE ''%balance%control%''
     OR EXISTS (
            SELECT 1
            FROM ' + QUOTENAME(@DbName) + N'.sys.columns AS c2
            WHERE c2.object_id = t.object_id
              AND (c2.name LIKE ''%source%count%'' OR c2.name LIKE ''%src%count%'')
        )
      )
GROUP BY s.name, t.name;';

        EXEC sys.sp_executesql @sql, N'@DbNameParam sysname', @DbNameParam = @DbName;

        /* Reconciliation routines */
        SET @sql = N'
INSERT INTO #ReconObj (DatabaseName, ObjectType, ObjectName, HasSourceCount, HasTargetCount, ApproxRows)
SELECT @DbNameParam, ''MODULE'', s.name + N''.'' + o.name, 0, 0, 0
FROM ' + QUOTENAME(@DbName) + N'.sys.objects AS o
INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas AS s ON s.schema_id = o.schema_id
LEFT JOIN ' + QUOTENAME(@DbName) + N'.sys.sql_modules AS m ON m.object_id = o.object_id
WHERE o.is_ms_shipped = 0
  AND o.type IN (''P'', ''V'', ''FN'', ''TF'', ''IF'')
  AND ( o.name LIKE ''%recon%''
     OR o.name LIKE ''%row%count%check%''
     OR o.name LIKE ''%count%control%''
     OR m.definition LIKE ''%reconcil%''
      );';

        EXEC sys.sp_executesql @sql, N'@DbNameParam sysname', @DbNameParam = @DbName;
    END TRY
    BEGIN CATCH
        SET @ErrMsg = LEFT(ERROR_MESSAGE(), 400);
        IF NOT EXISTS (SELECT 1 FROM #Err WHERE DatabaseName = @DbName)
            INSERT INTO #Err (DatabaseName, ErrMsg) VALUES (@DbName, @ErrMsg);
    END CATCH

    FETCH NEXT FROM db_cur INTO @DbName;
END

CLOSE db_cur;
DEALLOCATE db_cur;

INSERT INTO #DbScore (DatabaseName, ReconTables, Pairs, PopulatedPairs, Modules, DbScore)
SELECT d.DatabaseName,
       ISNULL(a.ReconTables, 0),
       ISNULL(a.Pairs, 0),
       ISNULL(a.PopulatedPairs, 0),
       ISNULL(a.Modules, 0),
       CASE
           WHEN ISNULL(a.PopulatedPairs, 0) >= 1 THEN 3
           WHEN ISNULL(a.Pairs, 0) >= 1 THEN 2
           WHEN ISNULL(a.ReconTables, 0) >= 1 AND ISNULL(a.Modules, 0) >= 1 THEN 2
           WHEN ISNULL(a.ReconTables, 0) >= 1 OR ISNULL(a.Modules, 0) >= 1 THEN 1
           ELSE 0
       END
FROM #Db AS d
LEFT JOIN (
    SELECT DatabaseName,
           SUM(CASE WHEN ObjectType = 'TABLE' THEN 1 ELSE 0 END) AS ReconTables,
           SUM(CASE WHEN ObjectType = 'TABLE' AND HasSourceCount = 1 AND HasTargetCount = 1 THEN 1 ELSE 0 END) AS Pairs,
           SUM(CASE WHEN ObjectType = 'TABLE' AND HasSourceCount = 1 AND HasTargetCount = 1 AND ApproxRows > 0 THEN 1 ELSE 0 END) AS PopulatedPairs,
           SUM(CASE WHEN ObjectType = 'MODULE' THEN 1 ELSE 0 END) AS Modules
    FROM #ReconObj
    GROUP BY DatabaseName
) AS a ON a.DatabaseName = d.DatabaseName
WHERE NOT EXISTS (SELECT 1 FROM #Err AS e WHERE e.DatabaseName = d.DatabaseName);

DECLARE @Evaluated int = (SELECT COUNT(*) FROM #DbScore);
DECLARE @Skipped   int = (SELECT COUNT(*) FROM #Err);
DECLARE @FailList  nvarchar(max);
DECLARE @PassCount int;

IF @Evaluated = 0
BEGIN
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
    SET @Score = 0;
END
ELSE
BEGIN
    SELECT @DatabaseQueried = STUFF((
            SELECT N', ' + x.DatabaseName
            FROM #DbScore AS x
            ORDER BY x.DatabaseName
            FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

    SELECT @FailList = STUFF((
            SELECT N', ' + x.DatabaseName
            FROM #DbScore AS x
            WHERE x.DbScore = 0
            ORDER BY x.DatabaseName
            FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

    IF @DatabaseQueried IS NULL SET @DatabaseQueried = N'None';
    IF @FailList IS NULL SET @FailList = N'';
    IF LEN(@DatabaseQueried) > 300 SET @DatabaseQueried = LEFT(@DatabaseQueried, 297) + N'...';
    IF LEN(@FailList) > 300 SET @FailList = LEFT(@FailList, 297) + N'...';

    SET @PassCount = (SELECT COUNT(*) FROM #DbScore WHERE DbScore = 3);
    SET @Score = (SELECT MIN(DbScore) FROM #DbScore);

    SET @Finding =
        N'Inspected ' + CONVERT(nvarchar(10), @Evaluated) + N' user database(s) for record count reconciliation artifacts (control/audit/balance tables carrying source vs target count columns, and reconciliation routines). '
      + CONVERT(nvarchar(10), @PassCount) + N' database(s) hold a populated source/target count pair; '
      + CONVERT(nvarchar(10), (SELECT COUNT(*) FROM #DbScore WHERE DbScore IN (1, 2))) + N' database(s) have partial evidence only; '
      + CONVERT(nvarchar(10), (SELECT COUNT(*) FROM #DbScore WHERE DbScore = 0)) + N' database(s) have no reconciliation artifact'
      + CASE WHEN LEN(@FailList) > 0 THEN N' (' + @FailList + N')' ELSE N'' END + N'. '
      + N'Worst-case database score ' + CONVERT(nvarchar(10), @Score) + N' is reported. '
      + N'Totals found: ' + CONVERT(nvarchar(10), (SELECT COUNT(*) FROM #ReconObj WHERE ObjectType = 'TABLE')) + N' control table(s), '
      + CONVERT(nvarchar(10), (SELECT COUNT(*) FROM #ReconObj WHERE ObjectType = 'TABLE' AND HasSourceCount = 1 AND HasTargetCount = 1)) + N' with a source/target count column pair, '
      + CONVERT(nvarchar(10), (SELECT COUNT(*) FROM #ReconObj WHERE ObjectType = 'MODULE')) + N' reconciliation routine(s).'
      + CASE WHEN @Skipped > 0
             THEN N' ' + CONVERT(nvarchar(10), @Skipped) + N' database(s) were skipped because they could not be read.'
             ELSE N'' END;
END

SET @Result = CASE WHEN @Score = 3 THEN N'Pass'
                   WHEN @Score = 2 THEN N'Partial'
                   WHEN @Score = 1 THEN N'Partial'
                   ELSE N'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#Db') IS NOT NULL DROP TABLE #Db;
IF OBJECT_ID('tempdb..#Err') IS NOT NULL DROP TABLE #Err;
IF OBJECT_ID('tempdb..#ReconObj') IS NOT NULL DROP TABLE #ReconObj;
IF OBJECT_ID('tempdb..#DbScore') IS NOT NULL DROP TABLE #DbScore;