/* ============================================================================
   Checklist Item : 2.2.3
   Area           : Data Integration & ETL
   Description    : Watermark/control values persisted reliably
                    (control table, not volatile)
   Script Type    : SQL  (strictly read-only against user data and metadata)
   Scope          : SERVER (iterates accessible user databases)
   Output         : Result, Score, DatabaseQueried, Finding
   ============================================================================ */
SET NOCOUNT ON;

DECLARE @IsAzureSqlDb bit =
        CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#Db') IS NOT NULL DROP TABLE #Db;
CREATE TABLE #Db
(
    DatabaseName sysname NOT NULL PRIMARY KEY
);

IF OBJECT_ID('tempdb..#Control') IS NOT NULL DROP TABLE #Control;
CREATE TABLE #Control
(
    DatabaseName      sysname       NOT NULL,
    SchemaName        sysname       NOT NULL,
    TableName         sysname       NOT NULL,
    IsMemoryOptimized bit           NOT NULL,
    DurabilityDesc    nvarchar(60)  NULL,
    HasUniqueKey      bit           NOT NULL,
    MatchReason       nvarchar(100) NOT NULL
);

/* ---- databases in scope ---------------------------------------------------- */
IF @IsAzureSqlDb = 1
BEGIN
    INSERT INTO #Db (DatabaseName) VALUES (DB_NAME());
END
ELSE
BEGIN
    INSERT INTO #Db (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.name <> 'tempdb'
      AND d.state_desc = 'ONLINE'
      AND d.is_read_only = 0
      AND d.user_access_desc = 'MULTI_USER'
      AND HAS_DBACCESS(d.name) = 1
      AND DATABASEPROPERTYEX(d.name, 'Updateability') = 'READ_WRITE';
END

/* ---- pattern definitions --------------------------------------------------- */
DECLARE @TblPat nvarchar(max) =
    N'(t.name LIKE ''%watermark%'' OR t.name LIKE ''%water_mark%''' +
    N' OR t.name LIKE ''%high%water%'' OR t.name LIKE ''%etl%control%''' +
    N' OR t.name LIKE ''%load%control%'' OR t.name LIKE ''%batch%control%''' +
    N' OR t.name LIKE ''%extract%control%'' OR t.name LIKE ''%process%control%''' +
    N' OR t.name LIKE ''%control%table%'' OR t.name LIKE ''%checkpoint%''' +
    N' OR t.name LIKE ''%incremental%load%'')';

DECLARE @ColPat nvarchar(max) =
    N'(c.name LIKE ''%watermark%'' OR c.name LIKE ''%water_mark%''' +
    N' OR c.name LIKE ''%high%water%'' OR c.name LIKE ''%last%extract%''' +
    N' OR c.name LIKE ''%last%load%'' OR c.name LIKE ''%last%processed%''' +
    N' OR c.name LIKE ''%last%run%'' OR c.name LIKE ''%last%success%''' +
    N' OR c.name LIKE ''%checkpoint%'')';

/* In-memory OLTP durability columns only exist from SQL Server 2014 (v12). */
DECLARE @MemCols nvarchar(400) =
    CASE WHEN CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 12
         THEN N'CAST(t.is_memory_optimized AS bit), CAST(t.durability_desc AS nvarchar(60))'
         ELSE N'CAST(0 AS bit), CAST(NULL AS nvarchar(60))'
    END;

/* ---- collect candidate control tables per database -------------------------- */
DECLARE @DbName sysname;
DECLARE @Sql    nvarchar(max);
DECLARE @Pfx    nvarchar(300);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Db ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Pfx = CASE WHEN @IsAzureSqlDb = 1 THEN N'' ELSE QUOTENAME(@DbName) + N'.' END;

    SET @Sql =
        N'INSERT INTO #Control (DatabaseName, SchemaName, TableName, IsMemoryOptimized,' +
        N' DurabilityDesc, HasUniqueKey, MatchReason)' + NCHAR(13) + NCHAR(10) +
        N'SELECT ' + QUOTENAME(@DbName, '''') + N', s.name, t.name, ' + @MemCols + N',' + NCHAR(13) + NCHAR(10) +
        N'       CASE WHEN EXISTS (SELECT 1 FROM ' + @Pfx + N'sys.indexes AS i' + NCHAR(13) + NCHAR(10) +
        N'                         WHERE i.object_id = t.object_id' + NCHAR(13) + NCHAR(10) +
        N'                           AND (i.is_primary_key = 1 OR i.is_unique = 1))' + NCHAR(13) + NCHAR(10) +
        N'            THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END,' + NCHAR(13) + NCHAR(10) +
        N'       CASE WHEN ' + @TblPat + N' THEN N''Table name pattern''' +
        N' ELSE N''Column name pattern'' END' + NCHAR(13) + NCHAR(10) +
        N'FROM ' + @Pfx + N'sys.tables AS t' + NCHAR(13) + NCHAR(10) +
        N'INNER JOIN ' + @Pfx + N'sys.schemas AS s ON s.schema_id = t.schema_id' + NCHAR(13) + NCHAR(10) +
        N'WHERE t.is_ms_shipped = 0' + NCHAR(13) + NCHAR(10) +
        N'  AND ( ' + @TblPat + NCHAR(13) + NCHAR(10) +
        N'        OR EXISTS (SELECT 1 FROM ' + @Pfx + N'sys.columns AS c' + NCHAR(13) + NCHAR(10) +
        N'                   WHERE c.object_id = t.object_id AND ' + @ColPat + N') );';

    BEGIN TRY
        EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        /* database unreachable (offline, AG secondary, no permission) - skip it */
    END CATCH

    FETCH NEXT FROM db_cur INTO @DbName;
END

CLOSE db_cur;
DEALLOCATE db_cur;

/* ---- evaluate --------------------------------------------------------------- */
DECLARE @DbCount        int = (SELECT COUNT(*) FROM #Db);
DECLARE @TableCount     int = (SELECT COUNT(*) FROM #Control);
DECLARE @DbsWithControl int = (SELECT COUNT(DISTINCT DatabaseName) FROM #Control);
DECLARE @NonDurable     int = (SELECT COUNT(*) FROM #Control
                               WHERE IsMemoryOptimized = 1 AND DurabilityDesc = 'SCHEMA_ONLY');
DECLARE @NoKey          int = (SELECT COUNT(*) FROM #Control WHERE HasUniqueKey = 0);

DECLARE @DatabaseQueried nvarchar(max) =
    STUFF((SELECT N', ' + d.DatabaseName
           FROM #Db AS d
           ORDER BY d.DatabaseName
           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

IF @DatabaseQueried IS NULL OR LEN(@DatabaseQueried) = 0
    SET @DatabaseQueried = N'None (no accessible user databases)';

DECLARE @Sample nvarchar(max) =
    STUFF((SELECT TOP (10) N'; ' + w.DatabaseName + N'.' + w.SchemaName + N'.' + w.TableName
                  + CASE WHEN w.IsMemoryOptimized = 1 AND w.DurabilityDesc = 'SCHEMA_ONLY'
                         THEN N' [NON-DURABLE SCHEMA_ONLY]' ELSE N'' END
                  + CASE WHEN w.HasUniqueKey = 0 THEN N' [no PK/unique key]' ELSE N'' END
                  + N' (' + w.MatchReason + N')'
           FROM #Control AS w
           ORDER BY CASE WHEN w.IsMemoryOptimized = 1 AND w.DurabilityDesc = 'SCHEMA_ONLY' THEN 0
                         WHEN w.HasUniqueKey = 0 THEN 1
                         ELSE 2 END,
                    w.DatabaseName, w.SchemaName, w.TableName
           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

IF @Sample IS NULL SET @Sample = N'none';

DECLARE @Result  nvarchar(20);
DECLARE @Score   int;
DECLARE @Finding nvarchar(max);

IF @TableCount = 0
BEGIN
    SET @Score  = 0;
    SET @Finding = N'No persisted ETL watermark/control table was found in any of the '
                 + CAST(@DbCount AS nvarchar(10)) + N' accessible user database(s) scanned. '
                 + N'No permanent user table matched watermark/high-water-mark/ETL-control naming or '
                 + N'watermark-style column naming, so incremental-load control values appear to be held '
                 + N'in volatile structures (temp tables, table variables, package/pipeline variables) or '
                 + N'outside the database entirely.';
END
ELSE IF @NonDurable > 0
BEGIN
    SET @Score  = 1;
    SET @Finding = N'Found ' + CAST(@TableCount AS nvarchar(10)) + N' watermark/control table(s) across '
                 + CAST(@DbsWithControl AS nvarchar(10)) + N' of ' + CAST(@DbCount AS nvarchar(10))
                 + N' database(s), but ' + CAST(@NonDurable AS nvarchar(10))
                 + N' of them are memory-optimized with durability SCHEMA_ONLY, so their watermark values '
                 + N'are volatile and are lost on restart, failover or failback. Tables: ' + @Sample + N'.';
END
ELSE IF @NoKey > 0
BEGIN
    SET @Score  = 2;
    SET @Finding = N'Found ' + CAST(@TableCount AS nvarchar(10)) + N' durable watermark/control table(s) across '
                 + CAST(@DbsWithControl AS nvarchar(10)) + N' of ' + CAST(@DbCount AS nvarchar(10))
                 + N' database(s), so watermark values do survive restart, but ' + CAST(@NoKey AS nvarchar(10))
                 + N' of them have no primary key or unique index, so duplicate or ambiguous watermark rows '
                 + N'can accumulate undetected. Tables: ' + @Sample + N'.';
END
ELSE
BEGIN
    SET @Score  = 3;
    SET @Finding = N'All ' + CAST(@TableCount AS nvarchar(10)) + N' watermark/control table(s) found across '
                 + CAST(@DbsWithControl AS nvarchar(10)) + N' of ' + CAST(@DbCount AS nvarchar(10))
                 + N' database(s) are permanent, fully durable (no SCHEMA_ONLY memory-optimized tables) and '
                 + N'each carries a primary key or unique index, so watermark/control values are persisted '
                 + N'reliably and uniquely addressable. Tables: ' + @Sample + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

IF OBJECT_ID('tempdb..#Control') IS NOT NULL DROP TABLE #Control;
IF OBJECT_ID('tempdb..#Db') IS NOT NULL DROP TABLE #Db;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;