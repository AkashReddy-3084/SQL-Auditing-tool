/* ============================================================================
   Checklist Item : 5.2.7 - Source metadata captured (load timestamp, source, batch ID)
   Area           : 5.2 Data Quality Framework
   Scope          : DATABASE (all accessible user databases, aggregated)
   Nature         : READ-ONLY. Reads catalog views only; writes nothing except
                    session-local temp tables.
   Compatible     : SQL Server 2016+ and Azure SQL Database (EngineEdition 5).
   ============================================================================ */
SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

DECLARE @Result          VARCHAR(20)    = 'Fail';
DECLARE @Score           INT            = 0;
DECLARE @DatabaseQueried NVARCHAR(4000) = N'None';
DECLARE @Finding         NVARCHAR(4000) = N'No database found to be queried';

IF OBJECT_ID('tempdb..#DbList') IS NOT NULL DROP TABLE #DbList;
IF OBJECT_ID('tempdb..#Metrics') IS NOT NULL DROP TABLE #Metrics;

CREATE TABLE #DbList (DbName SYSNAME NOT NULL);

CREATE TABLE #Metrics
(
    DbName        SYSNAME        NOT NULL,
    TotalTables   INT            NULL,
    WithLoadTs    INT            NULL,
    WithSource    INT            NULL,
    WithBatch     INT            NULL,
    WithAllThree  INT            NULL,
    WithAny       INT            NULL,
    ErrMsg        NVARCHAR(400)  NULL
);

/* Azure SQL Database cannot query across databases: evaluate the current context only. */
IF @EngineEdition = 5
BEGIN
    INSERT INTO #DbList (DbName) VALUES (DB_NAME());
END
ELSE
BEGIN
    INSERT INTO #DbList (DbName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.is_in_standby = 0
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @Db    SYSNAME;
DECLARE @Sql   NVARCHAR(MAX);
DECLARE @Total INT, @Load INT, @Src INT, @Bat INT, @All3 INT, @Any INT;

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DbName FROM #DbList ORDER BY DbName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @Db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Total = NULL;
    SET @Load  = NULL;
    SET @Src   = NULL;
    SET @Bat   = NULL;
    SET @All3  = NULL;
    SET @Any   = NULL;

    SET @Sql = N'
    SELECT @o_Total = COUNT(*),
           @o_Load  = SUM(x.HasLoadTs),
           @o_Src   = SUM(x.HasSource),
           @o_Bat   = SUM(x.HasBatch),
           @o_All3  = SUM(CASE WHEN x.HasLoadTs = 1 AND x.HasSource = 1 AND x.HasBatch = 1 THEN 1 ELSE 0 END),
           @o_Any   = SUM(CASE WHEN x.HasLoadTs = 1 OR  x.HasSource = 1 OR  x.HasBatch = 1 THEN 1 ELSE 0 END)
    FROM
    (
        SELECT t.object_id,
               MAX(CASE
                     WHEN (LOWER(c.name) LIKE ''%load%''
                        OR LOWER(c.name) LIKE ''%insert%''
                        OR LOWER(c.name) LIKE ''%etl%''
                        OR LOWER(c.name) LIKE ''%ingest%''
                        OR LOWER(c.name) LIKE ''%extract%''
                        OR LOWER(c.name) LIKE ''%processed%''
                        OR LOWER(c.name) LIKE ''%created%'')
                      AND ty.name IN (''date'',''datetime'',''datetime2'',''smalldatetime'',''datetimeoffset'')
                     THEN 1 ELSE 0
                   END) AS HasLoadTs,
               MAX(CASE
                     WHEN LOWER(c.name) LIKE ''%source%''
                       OR LOWER(c.name) LIKE ''%src[_]%''
                       OR LOWER(c.name) LIKE ''%srcsystem%''
                       OR LOWER(c.name) LIKE ''%origin%''
                       OR LOWER(c.name) LIKE ''%system[_]of[_]record%''
                     THEN 1 ELSE 0
                   END) AS HasSource,
               MAX(CASE
                     WHEN LOWER(c.name) LIKE ''%batch%''
                       OR LOWER(c.name) LIKE ''%runid%''
                       OR LOWER(c.name) LIKE ''%run[_]id%''
                       OR LOWER(c.name) LIKE ''%loadid%''
                       OR LOWER(c.name) LIKE ''%load[_]id%''
                       OR LOWER(c.name) LIKE ''%jobid%''
                       OR LOWER(c.name) LIKE ''%job[_]id%''
                       OR LOWER(c.name) LIKE ''%execution[_]id%''
                       OR LOWER(c.name) LIKE ''%packageid%''
                       OR LOWER(c.name) LIKE ''%package[_]id%''
                     THEN 1 ELSE 0
                   END) AS HasBatch
        FROM ' + QUOTENAME(@Db) + N'.sys.tables   AS t
        INNER JOIN ' + QUOTENAME(@Db) + N'.sys.schemas AS s  ON s.schema_id     = t.schema_id
        INNER JOIN ' + QUOTENAME(@Db) + N'.sys.columns AS c  ON c.object_id     = t.object_id
        INNER JOIN ' + QUOTENAME(@Db) + N'.sys.types   AS ty ON ty.user_type_id = c.user_type_id
        WHERE t.is_ms_shipped = 0
          AND t.type = ''U''
          AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'')
        GROUP BY t.object_id
    ) AS x;';

    BEGIN TRY
        EXEC sys.sp_executesql
             @Sql,
             N'@o_Total INT OUTPUT, @o_Load INT OUTPUT, @o_Src INT OUTPUT, @o_Bat INT OUTPUT, @o_All3 INT OUTPUT, @o_Any INT OUTPUT',
             @o_Total = @Total OUTPUT,
             @o_Load  = @Load  OUTPUT,
             @o_Src   = @Src   OUTPUT,
             @o_Bat   = @Bat   OUTPUT,
             @o_All3  = @All3  OUTPUT,
             @o_Any   = @Any   OUTPUT;

        INSERT INTO #Metrics (DbName, TotalTables, WithLoadTs, WithSource, WithBatch, WithAllThree, WithAny, ErrMsg)
        VALUES (@Db, ISNULL(@Total, 0), ISNULL(@Load, 0), ISNULL(@Src, 0), ISNULL(@Bat, 0), ISNULL(@All3, 0), ISNULL(@Any, 0), NULL);
    END TRY
    BEGIN CATCH
        INSERT INTO #Metrics (DbName, TotalTables, WithLoadTs, WithSource, WithBatch, WithAllThree, WithAny, ErrMsg)
        VALUES (@Db, NULL, NULL, NULL, NULL, NULL, NULL, LEFT(ERROR_MESSAGE(), 400));
    END CATCH

    FETCH NEXT FROM db_cur INTO @Db;
END

CLOSE db_cur;
DEALLOCATE db_cur;

DECLARE @DbCount   INT = 0;
DECLARE @ErrCount  INT = 0;
DECLARE @TotTables INT = 0;
DECLARE @TotLoad   INT = 0;
DECLARE @TotSrc    INT = 0;
DECLARE @TotBat    INT = 0;
DECLARE @TotAll3   INT = 0;
DECLARE @TotAny    INT = 0;

SELECT @DbCount   = COUNT(*),
       @ErrCount  = SUM(CASE WHEN m.ErrMsg IS NOT NULL THEN 1 ELSE 0 END),
       @TotTables = SUM(ISNULL(m.TotalTables, 0)),
       @TotLoad   = SUM(ISNULL(m.WithLoadTs, 0)),
       @TotSrc    = SUM(ISNULL(m.WithSource, 0)),
       @TotBat    = SUM(ISNULL(m.WithBatch, 0)),
       @TotAll3   = SUM(ISNULL(m.WithAllThree, 0)),
       @TotAny    = SUM(ISNULL(m.WithAny, 0))
FROM #Metrics AS m;

IF ISNULL(@DbCount, 0) = 0
BEGIN
    /* No user database qualified for inspection - mandated no-database contract. */
    SET @DatabaseQueried = N'None';
    SET @Finding         = N'No database found to be queried';
    SET @Score           = 0;
END
ELSE
BEGIN
    DECLARE @PctAll DECIMAL(5,1) = CASE WHEN ISNULL(@TotTables, 0) = 0 THEN 0
                                        ELSE CAST((@TotAll3 * 100.0) / @TotTables AS DECIMAL(5,1)) END;
    DECLARE @PctAny DECIMAL(5,1) = CASE WHEN ISNULL(@TotTables, 0) = 0 THEN 0
                                        ELSE CAST((@TotAny  * 100.0) / @TotTables AS DECIMAL(5,1)) END;

    SELECT @DatabaseQueried = STUFF((SELECT N', ' + m.DbName
                                     FROM #Metrics AS m
                                     ORDER BY m.DbName
                                     FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

    IF @DatabaseQueried IS NULL OR LEN(@DatabaseQueried) = 0
        SET @DatabaseQueried = N'None';

    /* Databases where not a single table carries any lineage attribute. */
    DECLARE @WorstDbs NVARCHAR(2000);

    SELECT @WorstDbs = STUFF((SELECT N', ' + m.DbName
                              FROM #Metrics AS m
                              WHERE m.ErrMsg IS NULL
                                AND ISNULL(m.TotalTables, 0) > 0
                                AND ISNULL(m.WithAny, 0) = 0
                              ORDER BY m.DbName
                              FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

    IF ISNULL(@TotTables, 0) = 0
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'No user tables exist across the ' + CAST(@DbCount AS NVARCHAR(20))
                     + N' database(s) examined, so no source-metadata columns are required.';
    END
    ELSE
    BEGIN
        SET @Score = CASE
                       WHEN @PctAll >= 80                   THEN 3
                       WHEN @PctAll >= 50 OR @PctAny >= 80  THEN 2
                       WHEN @PctAny >= 25                   THEN 1
                       ELSE 0
                     END;

        SET @Finding = CAST(@TotTables AS NVARCHAR(20)) + N' user table(s) across '
                     + CAST(@DbCount AS NVARCHAR(20)) + N' database(s) examined. '
                     + CAST(@TotAll3 AS NVARCHAR(20)) + N' (' + CAST(@PctAll AS NVARCHAR(10))
                     + N'%) carry all three lineage attributes. Individually: '
                     + CAST(@TotLoad AS NVARCHAR(20)) + N' have a load timestamp column, '
                     + CAST(@TotSrc AS NVARCHAR(20)) + N' have a source identifier column, '
                     + CAST(@TotBat AS NVARCHAR(20)) + N' have a batch/run ID column. '
                     + CAST(@TotAny AS NVARCHAR(20)) + N' (' + CAST(@PctAny AS NVARCHAR(10))
                     + N'%) carry at least one lineage attribute.'
                     + CASE WHEN @WorstDbs IS NULL THEN N''
                            ELSE N' Databases with no lineage metadata at all: ' + @WorstDbs + N'.' END;
    END

    IF ISNULL(@ErrCount, 0) > 0
        SET @Finding = @Finding + N' ' + CAST(@ErrCount AS NVARCHAR(20))
                     + N' database(s) could not be read and are excluded from the counts.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result                        AS Result,
       @Score                         AS Score,
       LEFT(@DatabaseQueried, 4000)   AS DatabaseQueried,
       LEFT(@Finding, 4000)           AS Finding;

IF OBJECT_ID('tempdb..#DbList') IS NOT NULL DROP TABLE #DbList;
IF OBJECT_ID('tempdb..#Metrics') IS NOT NULL DROP TABLE #Metrics;