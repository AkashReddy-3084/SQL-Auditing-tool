/* Checklist 5.3.7 - No duplicate grain in fact tables
   Read-only. Identifies fact tables by schema/naming convention, derives a proxy grain
   from foreign-key columns (fallback: non-identity *Key/*Id/*SK columns) and tests each
   table for duplicate rows at that grain. Only #temp tables are written to. */
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @IsAzureDb bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;
DECLARE @MaxScanRows bigint = 100000000;   -- tables larger than this are reported as not evaluated

IF OBJECT_ID('tempdb..#Db') IS NOT NULL DROP TABLE #Db;
IF OBJECT_ID('tempdb..#Fact') IS NOT NULL DROP TABLE #Fact;
IF OBJECT_ID('tempdb..#GrainCol') IS NOT NULL DROP TABLE #GrainCol;
IF OBJECT_ID('tempdb..#GrainAgg') IS NOT NULL DROP TABLE #GrainAgg;
IF OBJECT_ID('tempdb..#UqCol') IS NOT NULL DROP TABLE #UqCol;

CREATE TABLE #Db (DbName sysname NOT NULL);

CREATE TABLE #Fact (
    DbName          sysname       NOT NULL,
    SchemaName      sysname       NOT NULL,
    TableName       sysname       NOT NULL,
    ObjectId        int           NOT NULL,
    RowCnt          bigint        NULL,
    GrainCols       nvarchar(max) NULL,
    GrainCnt        int           NOT NULL DEFAULT (0),
    UniqueEnforced  bit           NOT NULL DEFAULT (0),
    DupGrain        int           NULL,          -- 1 = duplicates found, 0 = clean, NULL = not evaluated
    EvalNote        nvarchar(300) NULL
);

CREATE TABLE #GrainCol (
    DbName     sysname NOT NULL,
    ObjectId   int     NOT NULL,
    ColumnId   int     NOT NULL,
    ColumnName sysname NOT NULL
);

CREATE TABLE #GrainAgg (
    DbName   sysname       NOT NULL,
    ObjectId int           NOT NULL,
    Cnt      int           NOT NULL,
    Cols     nvarchar(max) NULL
);

CREATE TABLE #UqCol (
    DbName     sysname NOT NULL,
    ObjectId   int     NOT NULL,
    IndexId    int     NOT NULL,
    ColumnName sysname NOT NULL
);

IF @IsAzureDb = 1
    INSERT INTO #Db (DbName) SELECT DB_NAME();
ELSE
    INSERT INTO #Db (DbName)
    SELECT d.name
    FROM sys.databases d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.source_database_id IS NULL
      AND d.is_in_standby = 0
      AND HAS_DBACCESS(d.name) = 1
      AND d.name NOT IN (N'SSISDB', N'ReportServer', N'ReportServerTempDB', N'distribution');

DECLARE @Db sysname, @Sql nvarchar(max);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR SELECT DbName FROM #Db ORDER BY DbName;
OPEN db_cur;
FETCH NEXT FROM db_cur INTO @Db;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'
INSERT INTO #Fact (DbName, SchemaName, TableName, ObjectId, RowCnt)
SELECT @db, s.name, t.name, t.object_id,
       ISNULL((SELECT SUM(p.rows) FROM ' + QUOTENAME(@Db) + N'.sys.partitions p
               WHERE p.object_id = t.object_id AND p.index_id IN (0,1)), 0)
FROM ' + QUOTENAME(@Db) + N'.sys.tables t
JOIN ' + QUOTENAME(@Db) + N'.sys.schemas s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
  AND t.type = ''U''
  AND ( s.name IN (N''Fact'', N''fact'', N''FACT'')
        OR t.name LIKE N''Fact%''
        OR t.name LIKE N''fact[_]%''
        OR t.name LIKE N''Fct[_]%''
        OR t.name LIKE N''F[_]%''
        OR t.name LIKE N''%[_]Fact''
        OR t.name LIKE N''%Fact'' );

/* Preferred grain: the foreign-key (dimension key) columns of the fact table */
INSERT INTO #GrainCol (DbName, ObjectId, ColumnId, ColumnName)
SELECT @db, c.object_id, c.column_id, c.name
FROM ' + QUOTENAME(@Db) + N'.sys.columns c
WHERE EXISTS (SELECT 1 FROM #Fact f WHERE f.DbName = @db AND f.ObjectId = c.object_id)
  AND EXISTS (SELECT 1 FROM ' + QUOTENAME(@Db) + N'.sys.foreign_key_columns fkc
              WHERE fkc.parent_object_id = c.object_id AND fkc.parent_column_id = c.column_id);

/* Fallback grain for fact tables without declared foreign keys */
INSERT INTO #GrainCol (DbName, ObjectId, ColumnId, ColumnName)
SELECT @db, c.object_id, c.column_id, c.name
FROM ' + QUOTENAME(@Db) + N'.sys.columns c
JOIN ' + QUOTENAME(@Db) + N'.sys.types ty ON ty.user_type_id = c.user_type_id
WHERE EXISTS (SELECT 1 FROM #Fact f WHERE f.DbName = @db AND f.ObjectId = c.object_id)
  AND NOT EXISTS (SELECT 1 FROM #GrainCol g WHERE g.DbName = @db AND g.ObjectId = c.object_id)
  AND c.is_identity = 0
  AND c.is_computed = 0
  AND (c.name LIKE N''%Key'' OR c.name LIKE N''%Id'' OR c.name LIKE N''%[_]SK'' OR c.name LIKE N''%SK'')
  AND ty.name NOT IN (N''text'', N''ntext'', N''image'', N''xml'', N''geography'', N''geometry'', N''hierarchyid'');

/* Unique indexes / primary keys that may already enforce the grain */
INSERT INTO #UqCol (DbName, ObjectId, IndexId, ColumnName)
SELECT @db, i.object_id, i.index_id, c.name
FROM ' + QUOTENAME(@Db) + N'.sys.indexes i
JOIN ' + QUOTENAME(@Db) + N'.sys.index_columns ic
     ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
JOIN ' + QUOTENAME(@Db) + N'.sys.columns c
     ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.is_unique = 1
  AND i.is_disabled = 0
  AND EXISTS (SELECT 1 FROM #Fact f WHERE f.DbName = @db AND f.ObjectId = i.object_id);';

        EXEC sys.sp_executesql @Sql, N'@db sysname', @db = @Db;
    END TRY
    BEGIN CATCH
        /* Database not readable / insufficient permission - skip it */
        DELETE FROM #GrainCol WHERE DbName = @Db;
        DELETE FROM #UqCol   WHERE DbName = @Db;
        DELETE FROM #Fact    WHERE DbName = @Db;
    END CATCH

    FETCH NEXT FROM db_cur INTO @Db;
END
CLOSE db_cur;
DEALLOCATE db_cur;

/* Materialise the grain column list per fact table */
INSERT INTO #GrainAgg (DbName, ObjectId, Cnt, Cols)
SELECT g.DbName, g.ObjectId, COUNT(*),
       STUFF((SELECT N',' + QUOTENAME(g2.ColumnName)
              FROM #GrainCol g2
              WHERE g2.DbName = g.DbName AND g2.ObjectId = g.ObjectId
              ORDER BY g2.ColumnId
              FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, N'')
FROM #GrainCol g
GROUP BY g.DbName, g.ObjectId;

UPDATE #Fact
SET GrainCnt  = #GrainAgg.Cnt,
    GrainCols = #GrainAgg.Cols
FROM #Fact
JOIN #GrainAgg ON #GrainAgg.DbName = #Fact.DbName AND #GrainAgg.ObjectId = #Fact.ObjectId;

/* A unique index whose key columns are all grain columns already guarantees grain uniqueness */
UPDATE #Fact
SET UniqueEnforced = 1
WHERE #Fact.GrainCnt > 0
  AND EXISTS (
        SELECT u.IndexId
        FROM #UqCol u
        WHERE u.DbName = #Fact.DbName AND u.ObjectId = #Fact.ObjectId
        GROUP BY u.IndexId
        HAVING COUNT(*) = (SELECT COUNT(*)
                           FROM #UqCol u2
                           JOIN #GrainCol g
                             ON g.DbName = u2.DbName AND g.ObjectId = u2.ObjectId AND g.ColumnName = u2.ColumnName
                           WHERE u2.DbName = u.DbName AND u2.ObjectId = u.ObjectId AND u2.IndexId = u.IndexId)
  );

UPDATE #Fact
SET DupGrain = NULL,
    EvalNote = N'Not evaluated: no dimension/degenerate key columns could be derived for the grain'
WHERE GrainCnt = 0;

UPDATE #Fact
SET DupGrain = 0,
    EvalNote = N'Grain uniqueness enforced by a unique index/primary key'
WHERE GrainCnt > 0 AND UniqueEnforced = 1;

/* Data test for the remaining fact tables */
DECLARE @DbN sysname, @Sch sysname, @Tbl sysname, @Cols nvarchar(max), @Rows bigint, @Dup int;

DECLARE tbl_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DbName, SchemaName, TableName, GrainCols, RowCnt
    FROM #Fact
    WHERE GrainCnt > 0 AND UniqueEnforced = 0;
OPEN tbl_cur;
FETCH NEXT FROM tbl_cur INTO @DbN, @Sch, @Tbl, @Cols, @Rows;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF ISNULL(@Rows, 0) > @MaxScanRows
    BEGIN
        UPDATE #Fact
        SET DupGrain = NULL,
            EvalNote = N'Not evaluated: row count ' + CAST(@Rows AS nvarchar(30)) + N' exceeds the scan threshold'
        WHERE DbName = @DbN AND SchemaName = @Sch AND TableName = @Tbl;
    END
    ELSE
    BEGIN
        SET @Dup = NULL;
        BEGIN TRY
            SET @Sql = N'SELECT @dup = CASE WHEN EXISTS (SELECT 1 FROM '
                     + QUOTENAME(@DbN) + N'.' + QUOTENAME(@Sch) + N'.' + QUOTENAME(@Tbl)
                     + N' GROUP BY ' + @Cols + N' HAVING COUNT_BIG(*) > 1) THEN 1 ELSE 0 END;';
            EXEC sys.sp_executesql @Sql, N'@dup int OUTPUT', @dup = @Dup OUTPUT;

            UPDATE #Fact
            SET DupGrain = @Dup,
                EvalNote = CASE WHEN @Dup = 1
                                THEN N'Duplicate rows found at the derived grain'
                                ELSE N'No duplicate rows at the derived grain' END
            WHERE DbName = @DbN AND SchemaName = @Sch AND TableName = @Tbl;
        END TRY
        BEGIN CATCH
            UPDATE #Fact
            SET DupGrain = NULL,
                EvalNote = N'Not evaluated: ' + LEFT(ERROR_MESSAGE(), 200)
            WHERE DbName = @DbN AND SchemaName = @Sch AND TableName = @Tbl;
        END CATCH
    END

    FETCH NEXT FROM tbl_cur INTO @DbN, @Sch, @Tbl, @Cols, @Rows;
END
CLOSE tbl_cur;
DEALLOCATE tbl_cur;

DECLARE @TotalFact int, @DupTables int, @NotEval int, @Evaluated int, @PctDup int;

SELECT @TotalFact = COUNT(*),
       @DupTables = SUM(CASE WHEN DupGrain = 1 THEN 1 ELSE 0 END),
       @NotEval   = SUM(CASE WHEN DupGrain IS NULL THEN 1 ELSE 0 END)
FROM #Fact;

SET @TotalFact = ISNULL(@TotalFact, 0);
SET @DupTables = ISNULL(@DupTables, 0);
SET @NotEval   = ISNULL(@NotEval, 0);
SET @Evaluated = @TotalFact - @NotEval;
SET @PctDup    = CASE WHEN @Evaluated > 0 THEN (@DupTables * 100) / @Evaluated ELSE 0 END;

DECLARE @DupList nvarchar(max) = STUFF((
        SELECT TOP (10) N'; ' + f.DbName + N'.' + f.SchemaName + N'.' + f.TableName
                        + N' (grain: ' + ISNULL(f.GrainCols, N'n/a') + N')'
        FROM #Fact f
        WHERE f.DupGrain = 1
        ORDER BY f.DbName, f.SchemaName, f.TableName
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

DECLARE @SkipList nvarchar(max) = STUFF((
        SELECT TOP (10) N'; ' + f.DbName + N'.' + f.SchemaName + N'.' + f.TableName
                        + N' - ' + ISNULL(f.EvalNote, N'not evaluated')
        FROM #Fact f
        WHERE f.DupGrain IS NULL
        ORDER BY f.DbName, f.SchemaName, f.TableName
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

DECLARE @DbList nvarchar(max) = STUFF((
        SELECT N', ' + d.DbName
        FROM #Db d
        ORDER BY d.DbName
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

IF @DbList IS NULL SET @DbList = N'None';
IF LEN(@DbList) > 400 SET @DbList = LEFT(@DbList, 400) + N'...';

DECLARE @Result nvarchar(50), @Score int, @Finding nvarchar(max);

IF @TotalFact = 0
BEGIN
    SET @Score  = 1;
    SET @Finding = N'No fact tables could be identified by schema/naming convention (schema "Fact" or names such as Fact*, Fct_*, F_*, *_Fact) in the scanned databases: ' + @DbList
                 + N'. Fact tables and their declared grain must be confirmed manually against the data model.';
END
ELSE IF @DupTables > 0
BEGIN
    SET @Score  = CASE WHEN @PctDup <= 10 THEN 1 ELSE 0 END;
    SET @Finding = CAST(@DupTables AS nvarchar(10)) + N' of ' + CAST(@Evaluated AS nvarchar(10))
                 + N' evaluated fact table(s) (' + CAST(@PctDup AS nvarchar(10)) + N'%) contain duplicate rows at the derived grain. Offending tables: '
                 + ISNULL(@DupList, N'n/a')
                 + CASE WHEN @NotEval > 0 THEN N'. Additionally ' + CAST(@NotEval AS nvarchar(10)) + N' fact table(s) were not evaluated: ' + ISNULL(@SkipList, N'n/a') ELSE N'' END
                 + N'. Total fact tables identified: ' + CAST(@TotalFact AS nvarchar(10)) + N'.';
END
ELSE IF @Evaluated = 0
BEGIN
    SET @Score  = 1;
    SET @Finding = CAST(@TotalFact AS nvarchar(10)) + N' fact table(s) were identified but none could be evaluated for duplicate grain: '
                 + ISNULL(@SkipList, N'n/a') + N'. Grain uniqueness must be verified manually.';
END
ELSE IF @NotEval > 0
BEGIN
    SET @Score  = 2;
    SET @Finding = N'No duplicate grain was found in the ' + CAST(@Evaluated AS nvarchar(10))
                 + N' evaluated fact table(s), but ' + CAST(@NotEval AS nvarchar(10))
                 + N' of ' + CAST(@TotalFact AS nvarchar(10)) + N' fact table(s) could not be evaluated: '
                 + ISNULL(@SkipList, N'n/a') + N'.';
END
ELSE
BEGIN
    SET @Score  = 3;
    SET @Finding = N'All ' + CAST(@TotalFact AS nvarchar(10))
                 + N' identified fact table(s) were evaluated and none contain duplicate rows at the derived grain (grain taken from foreign-key/dimension key columns, or already enforced by a unique index).';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result  AS Result,
       @Score   AS Score,
       @DbList  AS DatabaseQueried,
       @Finding AS Finding;