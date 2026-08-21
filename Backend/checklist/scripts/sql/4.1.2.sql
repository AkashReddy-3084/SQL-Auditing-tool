/* ================================================================================
   Checklist Item : 4.1.2 - Naming conventions consistent for tables, columns and schemas
   Scope          : DATABASE (all accessible user databases, rolled up to one verdict)
   Access         : READ-ONLY - catalog views only (sys.tables, sys.columns, sys.schemas)
   Output         : Result, Score, DatabaseQueried, Finding
   ================================================================================ */

SET NOCOUNT ON;

DECLARE @Result          nvarchar(20);
DECLARE @Score           int;
DECLARE @DatabaseQueried nvarchar(max);
DECLARE @Finding         nvarchar(max);

IF OBJECT_ID('tempdb..#DbStats') IS NOT NULL
    DROP TABLE #DbStats;

IF OBJECT_ID('tempdb..#DbScore') IS NOT NULL
    DROP TABLE #DbScore;

CREATE TABLE #DbStats
(
    DatabaseName        sysname        NOT NULL,
    TotalTables         int            NOT NULL,
    TotalColumns        int            NOT NULL,
    TotalSchemas        int            NOT NULL,
    BadCharObjects      int            NOT NULL,
    BadStartObjects     int            NOT NULL,
    PrefixTables        int            NOT NULL,
    TableDeviations     int            NOT NULL,
    ColumnDeviations    int            NOT NULL,
    DominantTableStyle  nvarchar(30)   NULL,
    DominantColumnStyle nvarchar(30)   NULL
);

CREATE TABLE #DbScore
(
    DatabaseName sysname        NOT NULL,
    DbScore      int            NOT NULL,
    Detail       nvarchar(1000) NOT NULL
);

DECLARE @EngineEdition int = CAST(SERVERPROPERTY('EngineEdition') AS int);
DECLARE @SingleDb      bit = CASE WHEN @EngineEdition IN (5, 6, 9, 11) THEN 1 ELSE 0 END;

DECLARE @DbName sysname;
DECLARE @Prefix nvarchar(300);
DECLARE @Sql    nvarchar(max);

/* Template: {P} = database prefix (empty on Azure SQL Database), {D} = escaped database name */
DECLARE @Template nvarchar(max) = N'
WITH Anchor AS
(
    SELECT 1 AS One
),
Tbl AS
(
    SELECT t.name AS ObjName
    FROM {P}sys.tables AS t
    INNER JOIN {P}sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0
      AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'')
),
Col AS
(
    SELECT c.name AS ObjName
    FROM {P}sys.columns AS c
    INNER JOIN {P}sys.tables AS t  ON t.object_id = c.object_id
    INNER JOIN {P}sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0
      AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'')
),
Sch AS
(
    SELECT s.name AS ObjName
    FROM {P}sys.schemas AS s
    WHERE s.schema_id < 16384
      AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'', ''guest'', ''dbo'')
),
TblStyle AS
(
    SELECT
        ObjName,
        CASE
            WHEN ObjName COLLATE Latin1_General_BIN2 = UPPER(ObjName) COLLATE Latin1_General_BIN2
                 AND ObjName COLLATE Latin1_General_BIN2 = LOWER(ObjName) COLLATE Latin1_General_BIN2 THEN N''NoCase''
            WHEN ObjName COLLATE Latin1_General_BIN2 = UPPER(ObjName) COLLATE Latin1_General_BIN2
                 AND ObjName COLLATE Latin1_General_BIN2 LIKE ''%[_]%'' THEN N''UPPER_SNAKE''
            WHEN ObjName COLLATE Latin1_General_BIN2 = UPPER(ObjName) COLLATE Latin1_General_BIN2 THEN N''UPPERCASE''
            WHEN ObjName COLLATE Latin1_General_BIN2 = LOWER(ObjName) COLLATE Latin1_General_BIN2
                 AND ObjName COLLATE Latin1_General_BIN2 LIKE ''%[_]%'' THEN N''snake_case''
            WHEN ObjName COLLATE Latin1_General_BIN2 = LOWER(ObjName) COLLATE Latin1_General_BIN2 THEN N''lowercase''
            WHEN ObjName COLLATE Latin1_General_BIN2 LIKE ''%[_]%'' THEN N''Mixed_Snake''
            WHEN LEFT(ObjName, 1) COLLATE Latin1_General_BIN2 = UPPER(LEFT(ObjName, 1)) COLLATE Latin1_General_BIN2 THEN N''PascalCase''
            ELSE N''camelCase''
        END AS Style
    FROM Tbl
),
ColStyle AS
(
    SELECT
        ObjName,
        CASE
            WHEN ObjName COLLATE Latin1_General_BIN2 = UPPER(ObjName) COLLATE Latin1_General_BIN2
                 AND ObjName COLLATE Latin1_General_BIN2 = LOWER(ObjName) COLLATE Latin1_General_BIN2 THEN N''NoCase''
            WHEN ObjName COLLATE Latin1_General_BIN2 = UPPER(ObjName) COLLATE Latin1_General_BIN2
                 AND ObjName COLLATE Latin1_General_BIN2 LIKE ''%[_]%'' THEN N''UPPER_SNAKE''
            WHEN ObjName COLLATE Latin1_General_BIN2 = UPPER(ObjName) COLLATE Latin1_General_BIN2 THEN N''UPPERCASE''
            WHEN ObjName COLLATE Latin1_General_BIN2 = LOWER(ObjName) COLLATE Latin1_General_BIN2
                 AND ObjName COLLATE Latin1_General_BIN2 LIKE ''%[_]%'' THEN N''snake_case''
            WHEN ObjName COLLATE Latin1_General_BIN2 = LOWER(ObjName) COLLATE Latin1_General_BIN2 THEN N''lowercase''
            WHEN ObjName COLLATE Latin1_General_BIN2 LIKE ''%[_]%'' THEN N''Mixed_Snake''
            WHEN LEFT(ObjName, 1) COLLATE Latin1_General_BIN2 = UPPER(LEFT(ObjName, 1)) COLLATE Latin1_General_BIN2 THEN N''PascalCase''
            ELSE N''camelCase''
        END AS Style
    FROM Col
),
TblDom AS
(
    SELECT TOP (1) Style, COUNT(*) AS Cnt
    FROM TblStyle
    GROUP BY Style
    ORDER BY COUNT(*) DESC, Style
),
ColDom AS
(
    SELECT TOP (1) Style, COUNT(*) AS Cnt
    FROM ColStyle
    GROUP BY Style
    ORDER BY COUNT(*) DESC, Style
)
INSERT INTO #DbStats
(
    DatabaseName, TotalTables, TotalColumns, TotalSchemas, BadCharObjects,
    BadStartObjects, PrefixTables, TableDeviations, ColumnDeviations,
    DominantTableStyle, DominantColumnStyle
)
SELECT
    CAST(N''{D}'' AS sysname),
    (SELECT COUNT(*) FROM Tbl),
    (SELECT COUNT(*) FROM Col),
    (SELECT COUNT(*) FROM Sch),
      (SELECT COUNT(*) FROM Tbl WHERE ObjName COLLATE Latin1_General_BIN2 LIKE ''%[^A-Za-z0-9_]%'')
    + (SELECT COUNT(*) FROM Col WHERE ObjName COLLATE Latin1_General_BIN2 LIKE ''%[^A-Za-z0-9_]%'')
    + (SELECT COUNT(*) FROM Sch WHERE ObjName COLLATE Latin1_General_BIN2 LIKE ''%[^A-Za-z0-9_]%''),
      (SELECT COUNT(*) FROM Tbl WHERE ObjName COLLATE Latin1_General_BIN2 LIKE ''[0-9_]%'')
    + (SELECT COUNT(*) FROM Col WHERE ObjName COLLATE Latin1_General_BIN2 LIKE ''[0-9_]%''),
    (SELECT COUNT(*) FROM Tbl
     WHERE ObjName COLLATE Latin1_General_BIN2 LIKE ''tbl%''
        OR ObjName COLLATE Latin1_General_BIN2 LIKE ''TBL%''
        OR ObjName COLLATE Latin1_General_BIN2 LIKE ''tb[_]%''
        OR ObjName COLLATE Latin1_General_BIN2 LIKE ''t[_]%''),
    (SELECT COUNT(*) FROM Tbl) - ISNULL((SELECT Cnt FROM TblDom), 0),
    (SELECT COUNT(*) FROM Col) - ISNULL((SELECT Cnt FROM ColDom), 0),
    (SELECT Style FROM TblDom),
    (SELECT Style FROM ColDom)
FROM Anchor;
';

IF @SingleDb = 1
BEGIN
    /* Azure SQL Database / Synapse / SQL Edge - current database only, no cross-database references */
    SET @DbName = DB_NAME();
    SET @Sql = REPLACE(REPLACE(@Template, N'{P}', N''), N'{D}', REPLACE(@DbName, '''', ''''''));

    BEGIN TRY
        EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        /* database not readable - leave it out of the result set */
    END CATCH
END
ELSE
BEGIN
    DECLARE DbCursor CURSOR LOCAL FAST_FORWARD READ_ONLY FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.is_in_standby = 0
          AND d.source_database_id IS NULL
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN DbCursor;
    FETCH NEXT FROM DbCursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Prefix = QUOTENAME(@DbName) + N'.';
        SET @Sql = REPLACE(REPLACE(@Template, N'{P}', @Prefix), N'{D}', REPLACE(@DbName, '''', ''''''));

        BEGIN TRY
            EXEC sys.sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            /* database not readable (offline replica, encrypted, insufficient rights) - skip it */
        END CATCH

        FETCH NEXT FROM DbCursor INTO @DbName;
    END

    CLOSE DbCursor;
    DEALLOCATE DbCursor;
END

/* ------------------------------------------------- per-database scoring roll-up */
INSERT INTO #DbScore (DatabaseName, DbScore, Detail)
SELECT
    s.DatabaseName,
    s.DbScore,
    CAST(
        QUOTENAME(s.DatabaseName) + N': '
        + CASE
            WHEN s.TotalTables = 0
                THEN N'no user tables to assess'
            ELSE CAST(s.TotalTables AS nvarchar(20)) + N' table(s)/'
               + CAST(s.TotalColumns AS nvarchar(20)) + N' column(s)/'
               + CAST(s.TotalSchemas AS nvarchar(20)) + N' user schema(s), '
               + N'dominant table style ' + ISNULL(s.DominantTableStyle, N'n/a')
               + N' and column style ' + ISNULL(s.DominantColumnStyle, N'n/a') + N', '
               + CAST(s.TableDeviations AS nvarchar(20)) + N' off-style table name(s), '
               + CAST(s.ColumnDeviations AS nvarchar(20)) + N' off-style column name(s), '
               + CAST(s.BadCharObjects AS nvarchar(20)) + N' name(s) with characters outside [A-Za-z0-9_], '
               + CAST(s.BadStartObjects AS nvarchar(20)) + N' name(s) starting with a digit/underscore, '
               + CAST(s.PrefixInconsistency AS nvarchar(20)) + N' inconsistent tbl/tb_/t_ prefix(es), '
               + N'consistency ' + CAST(s.ConformancePct AS nvarchar(20)) + N'%'
          END
        + N' (score ' + CAST(s.DbScore AS nvarchar(5)) + N')'
    AS nvarchar(1000))
FROM
(
    SELECT
        p.DatabaseName,
        p.TotalTables,
        p.TotalColumns,
        p.TotalSchemas,
        p.BadCharObjects,
        p.BadStartObjects,
        p.TableDeviations,
        p.ColumnDeviations,
        p.PrefixInconsistency,
        p.DominantTableStyle,
        p.DominantColumnStyle,
        p.ConformancePct,
        DbScore = CASE
            WHEN p.TotalTables = 0 THEN 3
            WHEN p.ConformancePct >= 95.0 AND p.BadCharObjects = 0 THEN 3
            WHEN p.ConformancePct >= 80.0 THEN 2
            ELSE 1
        END
    FROM
    (
        SELECT
            d.DatabaseName,
            d.TotalTables,
            d.TotalColumns,
            d.TotalSchemas,
            d.BadCharObjects,
            d.BadStartObjects,
            d.TableDeviations,
            d.ColumnDeviations,
            d.PrefixInconsistency,
            d.DominantTableStyle,
            d.DominantColumnStyle,
            ConformancePct = CASE
                WHEN d.TotalObjects = 0 THEN CAST(100.0 AS decimal(5, 1))
                WHEN d.Deviations >= d.TotalObjects THEN CAST(0.0 AS decimal(5, 1))
                ELSE CAST(100.0 * (d.TotalObjects - d.Deviations) / d.TotalObjects AS decimal(5, 1))
            END
        FROM
        (
            SELECT
                c.DatabaseName,
                c.TotalTables,
                c.TotalColumns,
                c.TotalSchemas,
                c.BadCharObjects,
                c.BadStartObjects,
                c.TableDeviations,
                c.ColumnDeviations,
                c.PrefixInconsistency,
                c.DominantTableStyle,
                c.DominantColumnStyle,
                c.TotalObjects,
                Deviations = c.TableDeviations + c.ColumnDeviations + c.BadCharObjects
                           + c.BadStartObjects + c.PrefixInconsistency
            FROM
            (
                SELECT
                    st.DatabaseName,
                    st.TotalTables,
                    st.TotalColumns,
                    st.TotalSchemas,
                    st.BadCharObjects,
                    st.BadStartObjects,
                    st.TableDeviations,
                    st.ColumnDeviations,
                    st.DominantTableStyle,
                    st.DominantColumnStyle,
                    PrefixInconsistency = CASE
                        WHEN st.PrefixTables = 0 OR st.PrefixTables = st.TotalTables THEN 0
                        WHEN st.PrefixTables <= st.TotalTables - st.PrefixTables THEN st.PrefixTables
                        ELSE st.TotalTables - st.PrefixTables
                    END,
                    TotalObjects = st.TotalTables + st.TotalColumns
                FROM #DbStats AS st
            ) AS c
        ) AS d
    ) AS p
) AS s;

/* ---------------------------------------------------------------- final verdict */
IF NOT EXISTS (SELECT 1 FROM #DbScore)
BEGIN
    SET @Score           = 0;
    SET @DatabaseQueried = N'None';
    SET @Finding         = N'No database found to be queried';
END
ELSE
BEGIN
    SELECT @Score = MIN(sc.DbScore) FROM #DbScore AS sc;

    SET @DatabaseQueried = STUFF(
        (
            SELECT N', ' + CAST(sc.DatabaseName AS nvarchar(128))
            FROM #DbScore AS sc
            ORDER BY sc.DatabaseName
            FOR XML PATH(''), TYPE
        ).value('.', 'nvarchar(max)'), 1, 2, N'');

    SET @Finding =
        N'Evaluated ' + CAST((SELECT COUNT(*) FROM #DbScore) AS nvarchar(20)) + N' user database(s): '
      + CAST((SELECT COUNT(*) FROM #DbScore WHERE DbScore = 3) AS nvarchar(20)) + N' consistent, '
      + CAST((SELECT COUNT(*) FROM #DbScore WHERE DbScore = 2) AS nvarchar(20)) + N' partially consistent, '
      + CAST((SELECT COUNT(*) FROM #DbScore WHERE DbScore = 1) AS nvarchar(20)) + N' inconsistent. '
      + CASE
            WHEN @Score = 3 THEN N'Table, column and schema names follow a single dominant convention in every database with no illegal characters. '
            WHEN @Score = 2 THEN N'At least one database applies its naming convention only partially (80-94.9% of names match the dominant style). '
            ELSE N'At least one database has largely inconsistent naming (under 80% of names match the dominant style) or names containing illegal characters. '
        END
      + N'Detail: '
      + STUFF(
            (
                SELECT N' | ' + sc.Detail
                FROM #DbScore AS sc
                ORDER BY sc.DbScore, sc.DatabaseName
                FOR XML PATH(''), TYPE
            ).value('.', 'nvarchar(max)'), 1, 3, N'');
END

SET @Result = CASE WHEN @Score = 3 THEN N'Pass' ELSE N'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#DbStats') IS NOT NULL
    DROP TABLE #DbStats;

IF OBJECT_ID('tempdb..#DbScore') IS NOT NULL
    DROP TABLE #DbScore;