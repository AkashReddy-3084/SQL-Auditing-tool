/*==============================================================================
  Checklist item : 1.2.4 - Data flow lineage is traceable end-to-end from source to mart
  Scope          : DATABASE (all accessible online user databases; current DB on Azure SQL)
  Type           : Read-only. Reads catalog views only; writes nothing but session temp tables.
  Output         : Result, Score, DatabaseQueried, Finding
==============================================================================*/
SET NOCOUNT ON;

DECLARE @IsAzureDb bit = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#TargetDb') IS NOT NULL DROP TABLE #TargetDb;
IF OBJECT_ID('tempdb..#Res') IS NOT NULL DROP TABLE #Res;
IF OBJECT_ID('tempdb..#Err') IS NOT NULL DROP TABLE #Err;

CREATE TABLE #TargetDb (DbName sysname NOT NULL PRIMARY KEY);
CREATE TABLE #Res
(
    DbName           sysname NOT NULL PRIMARY KEY,
    MartObjects      int NOT NULL,
    TraceableObjects int NOT NULL,
    SourceObjects    int NOT NULL,
    TotalObjects     int NOT NULL
);
CREATE TABLE #Err (DbName sysname NOT NULL PRIMARY KEY, ErrMsg nvarchar(2048) NULL);

IF @IsAzureDb = 1
BEGIN
    INSERT INTO #TargetDb (DbName) SELECT DB_NAME();
END
ELSE
BEGIN
    INSERT INTO #TargetDb (DbName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.name NOT IN ('SSISDB', 'ReportServer', 'ReportServerTempDB', 'distribution')
      AND d.state_desc = 'ONLINE'
      AND d.source_database_id IS NULL
      AND d.is_read_only = 0
      AND HAS_DBACCESS(d.name) = 1
      AND DATABASEPROPERTYEX(d.name, 'Updateability') = 'READ_WRITE';
END

DECLARE @Inner nvarchar(max) =
N'
SET NOCOUNT ON;
DECLARE @dbn sysname = DB_NAME();

DECLARE @Obj TABLE (object_id int NOT NULL PRIMARY KEY, IsMart bit NOT NULL, IsSource bit NOT NULL);

INSERT INTO @Obj (object_id, IsMart, IsSource)
SELECT o.object_id,
       CASE WHEN LOWER(s.name) IN (''mart'',''marts'',''dm'',''datamart'',''datamarts'',''dw'',''dwh'',''edw'',''dim'',''dims'',''fact'',''facts'',''rpt'',''report'',''reporting'',''presentation'',''gold'',''semantic'',''star'')
                 OR LOWER(o.name) LIKE ''dim[_]%''
                 OR LOWER(o.name) LIKE ''fact[_]%''
            THEN 1 ELSE 0 END AS IsMart,
       CASE WHEN LOWER(s.name) IN (''stg'',''stage'',''staging'',''src'',''source'',''land'',''landing'',''raw'',''ext'',''external'',''bronze'',''ods'',''ingest'',''import'',''integration'',''silver'')
                 OR LOWER(o.name) LIKE ''stg[_]%''
                 OR LOWER(o.name) LIKE ''staging[_]%''
                 OR LOWER(o.name) LIKE ''raw[_]%''
                 OR LOWER(o.name) LIKE ''src[_]%''
                 OR EXISTS (SELECT 1 FROM sys.columns AS c
                            WHERE c.object_id = o.object_id
                              AND LOWER(REPLACE(c.name, ''_'', '''')) IN
                                  (''sourcesystem'',''sourcesystemid'',''sourcesystemname'',''sourcesystemcode'',
                                   ''batchid'',''loadbatchid'',''etlbatchid'',''loadid'',
                                   ''loaddate'',''loaddatetime'',''loadedat'',''loadts'',''etlloaddate'',''dwloaddate'',
                                   ''sourcefile'',''sourcetable'',''sourcename'',''lineageid'',''etlrunid'',''runid''))
            THEN 1 ELSE 0 END AS IsSource
FROM sys.objects AS o
JOIN sys.schemas AS s ON s.schema_id = o.schema_id
WHERE o.type IN (''U'',''V'')
  AND o.is_ms_shipped = 0;

DECLARE @Dep TABLE (refing int NOT NULL, refed int NOT NULL, IsUpd bit NOT NULL, PRIMARY KEY (refing, refed));

INSERT INTO @Dep (refing, refed, IsUpd)
SELECT d.referencing_id,
       d.referenced_id,
       CONVERT(bit, MAX(CONVERT(tinyint, d.is_updated)))
FROM sys.sql_expression_dependencies AS d
WHERE d.referenced_id IS NOT NULL
  AND d.referenced_database_name IS NULL
  AND d.referenced_server_name IS NULL
  AND d.referencing_id <> d.referenced_id
GROUP BY d.referencing_id, d.referenced_id;

/* Lineage edge = consumer -> producer/source */
DECLARE @Edge TABLE (refing int NOT NULL, refed int NOT NULL, PRIMARY KEY (refing, refed));

INSERT INTO @Edge (refing, refed)
SELECT DISTINCT e.refing, e.refed
FROM (
        /* a view or function reads its referenced objects directly */
        SELECT d.refing AS refing, d.refed AS refed
        FROM @Dep AS d
        JOIN sys.objects AS o ON o.object_id = d.refing
        WHERE o.type IN (''V'',''FN'',''IF'',''TF'')
          AND d.IsUpd = 0
        UNION
        /* a load module writes a target and reads sources: target -> source */
        SELECT w.refed AS refing, r.refed AS refed
        FROM @Dep AS w
        JOIN @Dep AS r ON r.refing = w.refing AND r.IsUpd = 0 AND r.refed <> w.refed
        JOIN sys.objects AS m ON m.object_id = w.refing
        WHERE w.IsUpd = 1
          AND m.type IN (''P'',''PC'',''TR'',''FN'',''IF'',''TF'')
     ) AS e
WHERE e.refing <> e.refed;

/* Objects fed from another database or a linked server are traceable to an external source */
DECLARE @Ext TABLE (object_id int NOT NULL PRIMARY KEY);

INSERT INTO @Ext (object_id)
SELECT DISTINCT x.object_id
FROM (
        SELECT d.referencing_id AS object_id
        FROM sys.sql_expression_dependencies AS d
        WHERE d.referenced_database_name IS NOT NULL
           OR d.referenced_server_name IS NOT NULL
        UNION
        SELECT w.referenced_id AS object_id
        FROM sys.sql_expression_dependencies AS w
        WHERE w.is_updated = 1
          AND w.referenced_id IS NOT NULL
          AND EXISTS (SELECT 1
                      FROM sys.sql_expression_dependencies AS e
                      WHERE e.referencing_id = w.referencing_id
                        AND (e.referenced_database_name IS NOT NULL OR e.referenced_server_name IS NOT NULL))
     ) AS x
WHERE EXISTS (SELECT 1 FROM @Obj AS a WHERE a.object_id = x.object_id);

DECLARE @Reach TABLE (object_id int NOT NULL PRIMARY KEY);

WITH Walk AS
(
    SELECT m.object_id AS RootId, e.refed AS NodeId, 1 AS Lvl
    FROM @Obj AS m
    JOIN @Edge AS e ON e.refing = m.object_id
    WHERE m.IsMart = 1
    UNION ALL
    SELECT w.RootId, e.refed, w.Lvl + 1
    FROM Walk AS w
    JOIN @Edge AS e ON e.refing = w.NodeId
    WHERE w.Lvl < 6
)
INSERT INTO @Reach (object_id)
SELECT DISTINCT w.RootId
FROM Walk AS w
JOIN @Obj AS o ON o.object_id = w.NodeId AND o.IsSource = 1
OPTION (MAXRECURSION 0);

INSERT INTO #Res (DbName, MartObjects, TraceableObjects, SourceObjects, TotalObjects)
SELECT @dbn,
       (SELECT COUNT(*) FROM @Obj WHERE IsMart = 1),
       (SELECT COUNT(*) FROM @Obj AS o
         WHERE o.IsMart = 1
           AND (o.IsSource = 1
                OR EXISTS (SELECT 1 FROM @Reach AS r WHERE r.object_id = o.object_id)
                OR EXISTS (SELECT 1 FROM @Ext AS x WHERE x.object_id = o.object_id))),
       (SELECT COUNT(*) FROM @Obj WHERE IsSource = 1),
       (SELECT COUNT(*) FROM @Obj);
';

DECLARE @Db sysname, @ExecName nvarchar(400);
DECLARE DbCur CURSOR LOCAL FAST_FORWARD FOR SELECT DbName FROM #TargetDb ORDER BY DbName;
OPEN DbCur;
FETCH NEXT FROM DbCur INTO @Db;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        IF @IsAzureDb = 1
            EXEC sys.sp_executesql @Inner;
        ELSE
        BEGIN
            SET @ExecName = QUOTENAME(@Db) + N'.sys.sp_executesql';
            EXEC @ExecName @Inner;
        END
    END TRY
    BEGIN CATCH
        IF NOT EXISTS (SELECT 1 FROM #Err WHERE DbName = @Db)
            INSERT INTO #Err (DbName, ErrMsg) VALUES (@Db, LEFT(ERROR_MESSAGE(), 2048));
    END CATCH

    FETCH NEXT FROM DbCur INTO @Db;
END

CLOSE DbCur;
DEALLOCATE DbCur;

DECLARE @DbScanned int, @DbWithMart int, @TotMart int, @TotTrace int, @TotSource int, @ErrCount int;
DECLARE @Pct decimal(5,1), @Score int, @Result nvarchar(20);
DECLARE @DbList nvarchar(max), @Detail nvarchar(max), @Finding nvarchar(max);

SELECT @DbScanned = COUNT(*),
       @DbWithMart = SUM(CASE WHEN r.MartObjects > 0 THEN 1 ELSE 0 END),
       @TotMart = ISNULL(SUM(r.MartObjects), 0),
       @TotTrace = ISNULL(SUM(r.TraceableObjects), 0),
       @TotSource = ISNULL(SUM(r.SourceObjects), 0)
FROM #Res AS r;

SELECT @ErrCount = COUNT(*) FROM #Err;

SELECT @DbList = STUFF((SELECT N', ' + r.DbName
                        FROM #Res AS r
                        ORDER BY r.DbName
                        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

SELECT @Detail = STUFF((SELECT N'; ' + r.DbName + N': ' + CONVERT(varchar(10), r.TraceableObjects) + N'/' + CONVERT(varchar(10), r.MartObjects)
                               + N' mart objects traceable, ' + CONVERT(varchar(10), r.SourceObjects) + N' source/staging objects'
                        FROM #Res AS r
                        WHERE r.MartObjects > 0
                        ORDER BY r.DbName
                        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

SET @DbList = ISNULL(@DbList, N'None');
SET @Detail = ISNULL(@Detail, N'no database contains mart/dimensional-layer objects');

IF ISNULL(@DbScanned, 0) = 0
BEGIN
    SET @Score = 0;
    SET @Result = N'NeedsReview';
    SET @Finding = N'No accessible online user database was found, so data flow lineage could not be evaluated.';
END
ELSE IF @TotMart = 0
BEGIN
    SET @Score = 0;
    SET @Result = N'Fail';
    SET @Finding = N'No mart/dimensional-layer objects (mart/dm/dw/dim/fact/rpt/presentation schemas or dim_/fact_ prefixed objects) were identified across '
                   + CONVERT(varchar(10), @DbScanned) + N' database(s), so no end-to-end lineage from source to mart can be traced. '
                   + CONVERT(varchar(10), @TotSource) + N' source/staging-layer object(s) were found.';
END
ELSE
BEGIN
    SET @Pct = CONVERT(decimal(5,1), (@TotTrace * 100.0) / @TotMart);
    SET @Score = CASE WHEN @Pct >= 90 THEN 3
                      WHEN @Pct >= 70 THEN 2
                      WHEN @Pct >= 40 THEN 1
                      ELSE 0 END;
    SET @Result = CASE WHEN @Score = 3 THEN N'Pass' ELSE N'Fail' END;
    SET @Finding = CONVERT(varchar(10), @TotTrace) + N' of ' + CONVERT(varchar(10), @TotMart) + N' mart/dimensional objects ('
                   + CONVERT(varchar(10), @Pct) + N'%) across ' + CONVERT(varchar(10), @DbWithMart)
                   + N' database(s) can be traced back to a staging/source artifact via object dependencies, cross-database/linked-server references or source lineage columns. Breakdown: '
                   + @Detail + N'.';
END

IF @ErrCount > 0
    SET @Finding = @Finding + N' ' + CONVERT(varchar(10), @ErrCount) + N' database(s) could not be inspected (permission or availability error).';

SELECT @Result AS Result,
       @Score AS Score,
       @DbList AS DatabaseQueried,
       LEFT(@Finding, 3900) AS Finding;

IF OBJECT_ID('tempdb..#TargetDb') IS NOT NULL DROP TABLE #TargetDb;
IF OBJECT_ID('tempdb..#Res') IS NOT NULL DROP TABLE #Res;
IF OBJECT_ID('tempdb..#Err') IS NOT NULL DROP TABLE #Err;