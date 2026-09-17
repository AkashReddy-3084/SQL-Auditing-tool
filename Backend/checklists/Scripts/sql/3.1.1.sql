SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#NamingStats') IS NOT NULL
    DROP TABLE #NamingStats;
IF OBJECT_ID('tempdb..#Scored') IS NOT NULL
    DROP TABLE #Scored;

CREATE TABLE #NamingStats
(
    DatabaseName        sysname      NOT NULL,
    TotalObjects        int          NOT NULL,
    IrregularNames      int          NOT NULL,
    ReservedPrefixProcs int          NOT NULL,
    DominantStyle       nvarchar(20) NULL,
    DominantStyleCount  int          NOT NULL
);

DECLARE @IsAzureSqlDb bit =
    CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

DECLARE @Databases TABLE (DatabaseName sysname NOT NULL);

IF @IsAzureSqlDb = 1
    INSERT INTO @Databases (DatabaseName) VALUES (DB_NAME());
ELSE
    INSERT INTO @Databases (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.is_in_standby = 0
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1;

DECLARE @DbName sysname;
DECLARE @Prefix nvarchar(300);
DECLARE @Sql    nvarchar(max);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM @Databases ORDER BY DatabaseName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Prefix = CASE WHEN @IsAzureSqlDb = 1 THEN N'' ELSE QUOTENAME(@DbName) + N'.' END;

    SET @Sql = N'
WITH Objs AS
(
    SELECT o.name COLLATE Latin1_General_BIN2 AS ObjName, o.type AS ObjType
    FROM ' + @Prefix + N'sys.objects AS o
    WHERE o.is_ms_shipped = 0
      AND o.parent_object_id = 0
      AND o.type IN (''U'',''V'',''P'',''FN'',''IF'',''TF'')
),
Classified AS
(
    SELECT ObjName,
           ObjType,
           CASE
               WHEN ObjName LIKE ''%[^a-zA-Z0-9_]%'' THEN ''Irregular''
               WHEN ObjName = UPPER(ObjName) AND ObjName <> LOWER(ObjName) THEN ''UPPERCASE''
               WHEN ObjName = LOWER(ObjName) AND ObjName LIKE ''%[_]%'' THEN ''snake_case''
               WHEN ObjName = LOWER(ObjName) THEN ''lowercase''
               WHEN ObjName LIKE ''%[_]%'' THEN ''Mixed_Underscore''
               WHEN LEFT(ObjName, 1) = UPPER(LEFT(ObjName, 1))
                    AND LEFT(ObjName, 1) <> LOWER(LEFT(ObjName, 1)) THEN ''PascalCase''
               ELSE ''camelCase''
           END AS Style
    FROM Objs
)
INSERT INTO #NamingStats
    (DatabaseName, TotalObjects, IrregularNames, ReservedPrefixProcs, DominantStyle, DominantStyleCount)
SELECT @p_db,
       (SELECT COUNT(*) FROM Classified),
       (SELECT COUNT(*) FROM Classified WHERE Style = ''Irregular''),
       (SELECT COUNT(*) FROM Classified WHERE ObjType = ''P'' AND ObjName LIKE ''sp[_]%''),
       (SELECT TOP (1) c.Style FROM Classified AS c GROUP BY c.Style ORDER BY COUNT(*) DESC, c.Style),
       ISNULL((SELECT TOP (1) COUNT(*) FROM Classified AS c GROUP BY c.Style ORDER BY COUNT(*) DESC, c.Style), 0);';

    BEGIN TRY
        EXEC sys.sp_executesql @Sql, N'@p_db sysname', @p_db = @DbName;
    END TRY
    BEGIN CATCH
        /* Database unreadable at run time (offline, restoring, insufficient rights) - skipped. */
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

SELECT
    s.DatabaseName,
    s.TotalObjects,
    s.IrregularNames,
    s.ReservedPrefixProcs,
    s.DominantStyle,
    s.DominantStyleCount,
    CONVERT(decimal(5, 1),
        CASE WHEN s.TotalObjects = 0 THEN 100.0
             ELSE s.DominantStyleCount * 100.0 / s.TotalObjects END) AS ConsistencyPct,
    CONVERT(int,
        CASE
            WHEN s.TotalObjects = 0 THEN 3
            WHEN s.IrregularNames = 0
                 AND s.ReservedPrefixProcs = 0
                 AND (s.DominantStyleCount * 100.0 / s.TotalObjects) >= 90.0 THEN 3
            WHEN s.ReservedPrefixProcs = 0
                 AND (s.IrregularNames * 100.0 / s.TotalObjects) <= 2.0
                 AND (s.DominantStyleCount * 100.0 / s.TotalObjects) >= 70.0 THEN 2
            ELSE 1
        END) AS DbScore
INTO #Scored
FROM #NamingStats AS s;

DECLARE @Result          nvarchar(20);
DECLARE @Score           int;
DECLARE @Finding         nvarchar(4000);
DECLARE @DatabaseQueried nvarchar(1000);
DECLARE @DbCount         int;
DECLARE @PassCount       int;
DECLARE @PartialCount    int;
DECLARE @FailCount       int;
DECLARE @Detail          nvarchar(max);

SELECT @DbCount      = COUNT(*),
       @PassCount    = SUM(CASE WHEN DbScore = 3 THEN 1 ELSE 0 END),
       @PartialCount = SUM(CASE WHEN DbScore = 2 THEN 1 ELSE 0 END),
       @FailCount    = SUM(CASE WHEN DbScore = 1 THEN 1 ELSE 0 END)
FROM #Scored;

IF ISNULL(@DbCount, 0) = 0
BEGIN
    SET @Score = 0;
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
END
ELSE
BEGIN
    SELECT @Score = MIN(DbScore) FROM #Scored;

    SELECT @DatabaseQueried = LEFT(STUFF(
            (SELECT N', ' + sc.DatabaseName
             FROM #Scored AS sc
             ORDER BY sc.DatabaseName
             FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), 1000);

    SELECT @Detail = STUFF(
            (SELECT N'; ' + sc.DatabaseName
                    + N' [' + ISNULL(sc.DominantStyle, N'n/a') + N' '
                    + CONVERT(nvarchar(10), sc.ConsistencyPct) + N'% of '
                    + CONVERT(nvarchar(10), sc.TotalObjects) + N' objects, irregular names='
                    + CONVERT(nvarchar(10), sc.IrregularNames) + N', sp_ procs='
                    + CONVERT(nvarchar(10), sc.ReservedPrefixProcs) + N']'
             FROM #Scored AS sc
             WHERE sc.DbScore < 3
             ORDER BY sc.DbScore, sc.DatabaseName
             FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

    SET @Finding = LEFT(
        CONCAT(N'Analyzed object naming in ', @DbCount, N' user database(s): ',
               @PassCount, N' consistent (>=90% single dominant style, no irregular names, no sp_ prefixed procedures), ',
               @PartialCount, N' partially consistent, ',
               @FailCount, N' inconsistent. ',
               CASE WHEN @Detail IS NULL
                    THEN N'All databases follow a single dominant naming style.'
                    ELSE N'Databases below the standard: ' + @Detail + N'.'
               END), 4000);
END

SET @Result = CASE
                  WHEN @Score >= 3 THEN N'Pass'
                  WHEN @Score = 2 THEN N'Partial'
                  ELSE N'Fail'
              END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#Scored') IS NOT NULL
    DROP TABLE #Scored;
IF OBJECT_ID('tempdb..#NamingStats') IS NOT NULL
    DROP TABLE #NamingStats;