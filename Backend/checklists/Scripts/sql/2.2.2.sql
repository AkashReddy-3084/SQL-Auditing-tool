/* ============================================================================
   Checklist 2.2.2 - Full load reserved for small reference/dimension tables
                     or initial loads
   Technique : deterministic, strictly read-only metadata inspection
   Scope     : SERVER - loops over every accessible ONLINE user database
   Proxy     : a full load is evidenced by TRUNCATE TABLE inside a programmable
               object; the truncated table's row count decides whether the
               pattern is really reserved for small reference/dimension data.
   ============================================================================ */
SET NOCOUNT ON;

DECLARE @LargeRowThreshold  bigint = 1000000;
DECLARE @MediumRowThreshold bigint = 100000;

IF OBJECT_ID('tempdb..#Databases') IS NOT NULL DROP TABLE #Databases;
IF OBJECT_ID('tempdb..#FullLoad')  IS NOT NULL DROP TABLE #FullLoad;
IF OBJECT_ID('tempdb..#DbContext') IS NOT NULL DROP TABLE #DbContext;
IF OBJECT_ID('tempdb..#Skipped')   IS NOT NULL DROP TABLE #Skipped;

CREATE TABLE #Databases
(
    DatabaseName sysname NOT NULL PRIMARY KEY
);

CREATE TABLE #FullLoad
(
    DatabaseName sysname       NOT NULL,
    ModuleName   nvarchar(300) NOT NULL,
    TargetTable  nvarchar(300) NOT NULL,
    TargetRows   bigint        NOT NULL
);

CREATE TABLE #DbContext
(
    DatabaseName          sysname NOT NULL PRIMARY KEY,
    IncrementalIndicators int     NOT NULL,
    ModuleCount           int     NOT NULL
);

CREATE TABLE #Skipped
(
    DatabaseName sysname        NOT NULL,
    ErrorMessage nvarchar(2000) NULL
);

/* Azure SQL Database can only reach the database the session is connected to. */
IF SERVERPROPERTY('EngineEdition') = 5
    INSERT INTO #Databases (DatabaseName) VALUES (DB_NAME());
ELSE
    INSERT INTO #Databases (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state_desc = 'ONLINE'
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1;

DECLARE @DbName sysname;
DECLARE @Sql    nvarchar(max);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Databases ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'
;WITH Norm AS
(
    SELECT m.object_id,
           REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(m.definition,
                  N''['', N''''), N'']'', N''''), NCHAR(13), N'' ''), NCHAR(10), N'' ''),
                  NCHAR(9), N'' ''), N''  '', N'' ''), N''  '', N'' '')
                  COLLATE Latin1_General_CI_AS AS Def
    FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules AS m
    WHERE m.definition IS NOT NULL
      AND m.definition COLLATE Latin1_General_CI_AS LIKE N''%TRUNCATE%TABLE%''
),
Sized AS
(
    SELECT p.object_id, SUM(p.[rows]) AS TargetRows
    FROM ' + QUOTENAME(@DbName) + N'.sys.partitions AS p
    WHERE p.index_id IN (0, 1)
    GROUP BY p.object_id
)
SELECT DISTINCT
       @pDb,
       LEFT(QUOTENAME(ms.name) + N''.'' + QUOTENAME(mo.name), 300),
       LEFT(QUOTENAME(ts.name) + N''.'' + QUOTENAME(t.name), 300),
       ISNULL(sz.TargetRows, 0)
FROM Norm AS n
INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.objects AS mo ON mo.object_id = n.object_id
INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas AS ms ON ms.schema_id = mo.schema_id
INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.tables  AS t  ON t.is_ms_shipped = 0
INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas AS ts ON ts.schema_id = t.schema_id
LEFT  JOIN Sized AS sz ON sz.object_id = t.object_id
WHERE CHARINDEX(N''TRUNCATE TABLE '' + ts.name COLLATE Latin1_General_CI_AS + N''.''
                + t.name COLLATE Latin1_General_CI_AS, n.Def) > 0
   OR CHARINDEX(N''TRUNCATE TABLE '' + t.name COLLATE Latin1_General_CI_AS + N'' '',
                n.Def + N'' '') > 0;';

        INSERT INTO #FullLoad (DatabaseName, ModuleName, TargetTable, TargetRows)
        EXEC sys.sp_executesql @Sql, N'@pDb sysname', @pDb = @DbName;

        SET @Sql = N'
SELECT @pDb,
       (SELECT COUNT(*)
        FROM ' + QUOTENAME(@DbName) + N'.sys.tables AS t
        WHERE t.is_ms_shipped = 0
          AND (t.name COLLATE Latin1_General_CI_AS LIKE N''%WATERMARK%''
            OR t.name COLLATE Latin1_General_CI_AS LIKE N''%HIGH_WATER%''
            OR t.name COLLATE Latin1_General_CI_AS LIKE N''%LOADCONTROL%''
            OR t.name COLLATE Latin1_General_CI_AS LIKE N''%LOAD_CONTROL%''
            OR t.name COLLATE Latin1_General_CI_AS LIKE N''%ETLCONTROL%''
            OR t.name COLLATE Latin1_General_CI_AS LIKE N''%ETL_CONTROL%''))
     + (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.change_tracking_tables)
     + (SELECT COUNT(*)
        FROM ' + QUOTENAME(@DbName) + N'.sys.schemas AS s
        WHERE s.name COLLATE Latin1_General_CI_AS = N''cdc''),
       (SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.sql_modules);';

        INSERT INTO #DbContext (DatabaseName, IncrementalIndicators, ModuleCount)
        EXEC sys.sp_executesql @Sql, N'@pDb sysname', @pDb = @DbName;
    END TRY
    BEGIN CATCH
        INSERT INTO #Skipped (DatabaseName, ErrorMessage)
        VALUES (@DbName, LEFT(ERROR_MESSAGE(), 2000));
    END CATCH;

    FETCH NEXT FROM db_cur INTO @DbName;
END;

CLOSE db_cur;
DEALLOCATE db_cur;

DECLARE @DbCount      int = (SELECT COUNT(*) FROM #Databases);
DECLARE @SkippedCount int = (SELECT COUNT(*) FROM #Skipped);
DECLARE @ModuleTotal  int = (SELECT ISNULL(SUM(ModuleCount), 0) FROM #DbContext);
DECLARE @IncTotal     int = (SELECT ISNULL(SUM(IncrementalIndicators), 0) FROM #DbContext);

DECLARE @TotalTargets int = 0;
DECLARE @LargeCnt     int = 0;
DECLARE @MediumCnt    int = 0;
DECLARE @SmallCnt     int = 0;
DECLARE @MaxRows      bigint = 0;

;WITH Targets AS
(
    SELECT DatabaseName, TargetTable, MAX(TargetRows) AS TargetRows
    FROM #FullLoad
    GROUP BY DatabaseName, TargetTable
)
SELECT @TotalTargets = COUNT(*),
       @LargeCnt     = ISNULL(SUM(CASE WHEN TargetRows >= @LargeRowThreshold THEN 1 ELSE 0 END), 0),
       @MediumCnt    = ISNULL(SUM(CASE WHEN TargetRows >= @MediumRowThreshold
                                        AND TargetRows <  @LargeRowThreshold THEN 1 ELSE 0 END), 0),
       @SmallCnt     = ISNULL(SUM(CASE WHEN TargetRows <  @MediumRowThreshold THEN 1 ELSE 0 END), 0),
       @MaxRows      = ISNULL(MAX(TargetRows), 0)
FROM Targets;

DECLARE @DatabaseQueried nvarchar(max) =
    ISNULL(STUFF((SELECT N', ' + d.DatabaseName
                  FROM #Databases AS d
                  ORDER BY d.DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'None');

DECLARE @TopTargets nvarchar(max) =
    ISNULL(STUFF((SELECT TOP (5) N'; ' + x.DatabaseName + N'.' + x.TargetTable
                                + N' (' + CAST(x.TargetRows AS nvarchar(20)) + N' rows)'
                  FROM (SELECT DatabaseName, TargetTable, MAX(TargetRows) AS TargetRows
                        FROM #FullLoad
                        GROUP BY DatabaseName, TargetTable) AS x
                  ORDER BY x.TargetRows DESC, x.DatabaseName, x.TargetTable
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'none');

DECLARE @Result  nvarchar(20);
DECLARE @Score   int;
DECLARE @Finding nvarchar(max);

IF @DbCount = 0
BEGIN
    SET @Score   = 1;
    SET @Finding = N'No accessible ONLINE user database was found, so truncate-and-reload patterns could not be inspected and full-load scope could not be confirmed.';
END
ELSE IF @ModuleTotal = 0
BEGIN
    SET @Score   = 1;
    SET @Finding = N'No programmable objects exist in the ' + CAST(@DbCount AS nvarchar(10))
                 + N' database(s) inspected, so no in-database load logic could be examined. Loading is most likely performed by an external tool (ADF, SSIS, Databricks), leaving full-load scope unverifiable from SQL metadata.';
END
ELSE IF @LargeCnt > 0 AND @IncTotal = 0
BEGIN
    SET @Score   = 0;
    SET @Finding = CAST(@LargeCnt AS nvarchar(10))
                 + N' table(s) of 1,000,000 rows or more are fully reloaded by a TRUNCATE TABLE inside a programmable object, and no incremental mechanism (CDC schema, Change Tracking or watermark/control table) exists anywhere in the '
                 + CAST(@DbCount AS nvarchar(10)) + N' database(s) inspected. Largest reload targets: ' + @TopTargets + N'.';
END
ELSE IF @LargeCnt > 0
BEGIN
    SET @Score   = 1;
    SET @Finding = CAST(@LargeCnt AS nvarchar(10))
                 + N' table(s) of 1,000,000 rows or more are fully reloaded by a TRUNCATE TABLE inside a programmable object, so full load is not reserved for small reference/dimension tables. '
                 + CAST(@IncTotal AS nvarchar(10))
                 + N' incremental indicator(s) (CDC schema, Change Tracking or watermark/control table) exist elsewhere but are not applied to these tables. Largest reload targets: '
                 + @TopTargets + N'.';
END
ELSE IF @MediumCnt > 0
BEGIN
    SET @Score   = 2;
    SET @Finding = N'All ' + CAST(@TotalTargets AS nvarchar(10))
                 + N' truncate-and-reload target(s) are below 1,000,000 rows, but ' + CAST(@MediumCnt AS nvarchar(10))
                 + N' of them hold 100,000 rows or more (largest ' + CAST(@MaxRows AS nvarchar(20))
                 + N' rows), which is larger than typical reference/dimension data. Largest reload targets: ' + @TopTargets + N'.';
END
ELSE
BEGIN
    SET @Score   = 3;
    SET @Finding = CASE WHEN @TotalTargets = 0
                        THEN N'No truncate-and-reload pattern was found in any programmable object across the '
                             + CAST(@DbCount AS nvarchar(10)) + N' database(s) inspected ('
                             + CAST(@ModuleTotal AS nvarchar(10)) + N' modules scanned), so no oversized full load exists.'
                        ELSE N'All ' + CAST(@TotalTargets AS nvarchar(10))
                             + N' truncate-and-reload target(s) hold fewer than 100,000 rows (largest '
                             + CAST(@MaxRows AS nvarchar(20))
                             + N' rows), so full load is confined to small reference/dimension tables. Reload targets: '
                             + @TopTargets + N'.'
                   END;
END;

IF @SkippedCount > 0
    SET @Finding = @Finding + N' Note: ' + CAST(@SkippedCount AS nvarchar(10))
                 + N' database(s) were skipped because their metadata could not be read with the current permissions.';

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #FullLoad;
DROP TABLE #DbContext;
DROP TABLE #Skipped;
DROP TABLE #Databases;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;