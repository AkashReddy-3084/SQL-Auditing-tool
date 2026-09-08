/* Checklist 3.2.3 - Scalar UDFs avoided in hot paths (inlined/replaced where they hurt performance) */
/* Read-only: queries catalog views only. */
SET NOCOUNT ON;

DECLARE @Result          NVARCHAR(20),
        @Score           INT,
        @DatabaseQueried NVARCHAR(1000),
        @Finding         NVARCHAR(4000);

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @HasInlineable INT = CASE WHEN COL_LENGTH('sys.sql_modules', 'is_inlineable') IS NOT NULL THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;
IF OBJECT_ID('tempdb..#Res') IS NOT NULL DROP TABLE #Res;

CREATE TABLE #Dbs
(
    DatabaseName sysname NOT NULL PRIMARY KEY,
    CompatLevel  INT     NULL
);

CREATE TABLE #Res
(
    DatabaseName sysname        NOT NULL,
    TotalUdf     INT            NULL,
    NonInlined   INT            NULL,
    HotModules   INT            NULL,
    ComputedRefs INT            NULL,
    SampleList   NVARCHAR(2000) NULL,
    ErrMsg       NVARCHAR(400)  NULL,
    DbScore      INT            NULL
);

IF @EngineEdition = 5   /* Azure SQL Database: only the current database is reachable */
BEGIN
    INSERT INTO #Dbs (DatabaseName, CompatLevel)
    SELECT DB_NAME(), CAST(DATABASEPROPERTYEX(DB_NAME(), 'CompatibilityLevel') AS INT);
END
ELSE
BEGIN
    INSERT INTO #Dbs (DatabaseName, CompatLevel)
    SELECT d.name, d.compatibility_level
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.is_read_only = 0
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1
      AND DATABASEPROPERTYEX(d.name, 'Updateability') = N'READ_WRITE';
END

DECLARE @Db         sysname,
        @Compat     INT,
        @Prefix     NVARCHAR(300),
        @InlineExpr NVARCHAR(100),
        @Eff        INT,
        @Sql        NVARCHAR(MAX);

DECLARE @Total  INT,
        @Bad    INT,
        @Hot    INT,
        @Cc     INT,
        @Sample NVARCHAR(2000);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD READ_ONLY FOR
    SELECT DatabaseName, CompatLevel FROM #Dbs ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @Db, @Compat;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Prefix     = CASE WHEN @EngineEdition = 5 THEN N'' ELSE QUOTENAME(@Db) + N'.' END;
    SET @InlineExpr = CASE WHEN @HasInlineable = 1 THEN N'ISNULL(CAST(m.is_inlineable AS INT), 0)' ELSE N'0' END;
    SET @Eff        = CASE WHEN @HasInlineable = 1 AND ISNULL(@Compat, 0) >= 150 THEN 1 ELSE 0 END;

    SELECT @Total = NULL, @Bad = NULL, @Hot = NULL, @Cc = NULL, @Sample = NULL;

    SET @Sql = N'
;WITH udf AS (
    SELECT o.object_id AS ObjId,
           QUOTENAME(s.name) + N''.'' + QUOTENAME(o.name) AS FullName,
           CASE WHEN o.type = ''FS'' THEN 0 ELSE ' + @InlineExpr + N' * @EffCompat END AS EffInlined
    FROM ' + @Prefix + N'sys.objects AS o
    INNER JOIN ' + @Prefix + N'sys.schemas AS s ON s.schema_id = o.schema_id
    LEFT JOIN  ' + @Prefix + N'sys.sql_modules AS m ON m.object_id = o.object_id
    WHERE o.type IN (''FN'', ''FS'')
      AND o.is_ms_shipped = 0
), bad AS (
    SELECT ObjId, FullName FROM udf WHERE EffInlined = 0
), dep AS (
    SELECT d.referenced_id, d.referencing_id, ro.type AS RefType
    FROM ' + @Prefix + N'sys.sql_expression_dependencies AS d
    INNER JOIN ' + @Prefix + N'sys.objects AS ro ON ro.object_id = d.referencing_id
    WHERE d.referencing_class = 1
      AND d.referenced_id IS NOT NULL
      AND ro.is_ms_shipped = 0
)
SELECT @Total = (SELECT COUNT(*) FROM udf),
       @Bad   = (SELECT COUNT(*) FROM bad),
       @Hot   = (SELECT COUNT(DISTINCT d.referencing_id)
                 FROM dep AS d
                 INNER JOIN bad AS b ON b.ObjId = d.referenced_id
                 WHERE d.RefType IN (''P'', ''V'', ''TR'', ''TF'', ''IF'', ''FN'', ''RF'', ''PC'')),
       @Cc    = (SELECT COUNT(DISTINCT d.referencing_id)
                 FROM dep AS d
                 INNER JOIN bad AS b ON b.ObjId = d.referenced_id
                 WHERE d.RefType IN (''U'', ''C'', ''D'')),
       @Sample = NULLIF(LEFT(ISNULL(STUFF((SELECT TOP (5) N''; '' + x.FullName + N'' ('' + CAST(x.Cnt AS NVARCHAR(10)) + N'' caller(s))''
                                           FROM (SELECT b.FullName, COUNT(DISTINCT d.referencing_id) AS Cnt
                                                 FROM bad AS b
                                                 LEFT JOIN dep AS d ON d.referenced_id = b.ObjId
                                                 GROUP BY b.FullName) AS x
                                           ORDER BY x.Cnt DESC, x.FullName
                                           FOR XML PATH(''''), TYPE).value(''.'', ''nvarchar(max)''), 1, 2, N''''), N''''), 1900), N'''');';

    BEGIN TRY
        EXEC sys.sp_executesql
             @Sql,
             N'@EffCompat INT, @Total INT OUTPUT, @Bad INT OUTPUT, @Hot INT OUTPUT, @Cc INT OUTPUT, @Sample NVARCHAR(2000) OUTPUT',
             @EffCompat = @Eff,
             @Total  = @Total  OUTPUT,
             @Bad    = @Bad    OUTPUT,
             @Hot    = @Hot    OUTPUT,
             @Cc     = @Cc     OUTPUT,
             @Sample = @Sample OUTPUT;

        INSERT INTO #Res (DatabaseName, TotalUdf, NonInlined, HotModules, ComputedRefs, SampleList, ErrMsg)
        VALUES (@Db, ISNULL(@Total, 0), ISNULL(@Bad, 0), ISNULL(@Hot, 0), ISNULL(@Cc, 0), @Sample, NULL);
    END TRY
    BEGIN CATCH
        INSERT INTO #Res (DatabaseName, ErrMsg)
        VALUES (@Db, LEFT(ERROR_MESSAGE(), 400));
    END CATCH;

    FETCH NEXT FROM db_cur INTO @Db, @Compat;
END

CLOSE db_cur;
DEALLOCATE db_cur;

UPDATE #Res
SET DbScore = CASE WHEN ErrMsg IS NOT NULL                 THEN 2
                   WHEN ComputedRefs > 0 OR HotModules > 5 THEN 1
                   WHEN HotModules > 0                     THEN 2
                   ELSE 3 END;

DECLARE @DbCount   INT = (SELECT COUNT(*) FROM #Res),
        @FailCount INT = (SELECT COUNT(*) FROM #Res WHERE DbScore = 1),
        @PartCount INT = (SELECT COUNT(*) FROM #Res WHERE DbScore = 2),
        @ErrCount  INT = (SELECT COUNT(*) FROM #Res WHERE ErrMsg IS NOT NULL),
        @TotalUdf  INT = (SELECT ISNULL(SUM(TotalUdf), 0)     FROM #Res),
        @TotalBad  INT = (SELECT ISNULL(SUM(NonInlined), 0)   FROM #Res),
        @TotalHot  INT = (SELECT ISNULL(SUM(HotModules), 0)   FROM #Res),
        @TotalCc   INT = (SELECT ISNULL(SUM(ComputedRefs), 0) FROM #Res);

IF @DbCount = 0
BEGIN
    /* No user database qualified for inspection - mandated no-database outcome. */
    SET @DatabaseQueried = N'None';
    SET @Finding         = N'No database found to be queried';
    SET @Score           = 0;
END
ELSE
BEGIN
    SELECT @Score = MIN(DbScore) FROM #Res;
    SET @Score = ISNULL(@Score, 2);

    SET @DatabaseQueried = LEFT(ISNULL(STUFF((SELECT N', ' + r.DatabaseName
                                              FROM #Res AS r
                                              ORDER BY r.DatabaseName
                                              FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'None'), 1000);

    DECLARE @Detail NVARCHAR(MAX) =
        ISNULL(STUFF((SELECT TOP (10) N' | ' + r.DatabaseName + N': '
                             + CASE WHEN r.ErrMsg IS NOT NULL
                                    THEN N'not inspected (' + r.ErrMsg + N')'
                                    ELSE CAST(r.NonInlined AS NVARCHAR(10)) + N' non-inlined scalar UDF(s), '
                                       + CAST(r.HotModules AS NVARCHAR(10)) + N' calling module(s), '
                                       + CAST(r.ComputedRefs AS NVARCHAR(10)) + N' computed-column/constraint dependency(ies)'
                                       + ISNULL(N' [' + r.SampleList + N']', N'')
                               END
                      FROM #Res AS r
                      WHERE r.DbScore < 3
                      ORDER BY r.DbScore, r.DatabaseName
                      FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 3, N''), N'');

    SET @Finding = LEFT(N'Databases inspected: ' + CAST(@DbCount AS NVARCHAR(10))
                 + N' (failing: ' + CAST(@FailCount AS NVARCHAR(10))
                 + N', partial: ' + CAST(@PartCount AS NVARCHAR(10))
                 + N', not inspectable: ' + CAST(@ErrCount AS NVARCHAR(10)) + N'). '
                 + N'User scalar UDFs found: ' + CAST(@TotalUdf AS NVARCHAR(10))
                 + N'; not inlined at the current compatibility level: ' + CAST(@TotalBad AS NVARCHAR(10))
                 + N'; modules (procedures/views/functions/triggers) calling a non-inlined scalar UDF: ' + CAST(@TotalHot AS NVARCHAR(10))
                 + N'; computed columns/constraints depending on one: ' + CAST(@TotalCc AS NVARCHAR(10)) + N'.'
                 + CASE WHEN @Detail = N'' THEN N' No non-inlined scalar UDF is referenced from any hot code path.'
                        ELSE N' Details: ' + @Detail END, 4000);
END

SET @Result = CASE WHEN @Score >= 3 THEN N'Pass'
                   WHEN @Score = 2  THEN N'Partial'
                   ELSE N'Fail' END;

DROP TABLE #Res;
DROP TABLE #Dbs;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;