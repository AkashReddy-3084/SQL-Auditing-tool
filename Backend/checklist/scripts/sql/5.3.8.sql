/* Checklist 5.3.8 - Freshness validation: marts updated within SLA
   Read-only. Identifies mart-layer tables, their load/refresh timestamp column,
   the most recent refresh, and any freshness/SLA monitoring artifacts. */
SET NOCOUNT ON;

DECLARE @SlaHours int = 24;   /* default freshness SLA applied when none is defined in-database */

IF OBJECT_ID('tempdb..#Databases')  IS NOT NULL DROP TABLE #Databases;
IF OBJECT_ID('tempdb..#MartTables') IS NOT NULL DROP TABLE #MartTables;
IF OBJECT_ID('tempdb..#Artifacts')  IS NOT NULL DROP TABLE #Artifacts;

CREATE TABLE #Databases (DatabaseName sysname NOT NULL PRIMARY KEY);

CREATE TABLE #MartTables (
    DatabaseName    sysname       NOT NULL,
    SchemaName      sysname       NOT NULL,
    TableName       sysname       NOT NULL,
    FreshnessColumn sysname       NULL,
    LastRefresh     datetime2(3)  NULL
);

CREATE TABLE #Artifacts (
    DatabaseName sysname       NOT NULL,
    ObjectName   nvarchar(300) NOT NULL,
    ObjectType   nvarchar(60)  NOT NULL
);

DECLARE @IsAzureSqlDb bit =
    CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

IF @IsAzureSqlDb = 1
    INSERT INTO #Databases (DatabaseName) VALUES (DB_NAME());
ELSE
    INSERT INTO #Databases (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state_desc = N'ONLINE'
      AND d.source_database_id IS NULL
      AND d.name NOT IN (N'distribution', N'SSISDB', N'ReportServer', N'ReportServerTempDB')
      AND HAS_DBACCESS(d.name) = 1;

DECLARE @db sysname, @sql nvarchar(max);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Databases ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'
SELECT @dbname, s.name, t.name, fc.ColName
FROM ' + QUOTENAME(@db) + N'.sys.tables AS t
INNER JOIN ' + QUOTENAME(@db) + N'.sys.schemas AS s ON s.schema_id = t.schema_id
OUTER APPLY (
    SELECT TOP (1) c.name AS ColName
    FROM ' + QUOTENAME(@db) + N'.sys.columns AS c
    INNER JOIN ' + QUOTENAME(@db) + N'.sys.types AS ty ON ty.user_type_id = c.user_type_id
    WHERE c.object_id = t.object_id
      AND ty.name IN (''datetime'',''datetime2'',''smalldatetime'',''datetimeoffset'',''date'')
      AND (c.name LIKE ''%load%date%''    OR c.name LIKE ''%loaddt%''
        OR c.name LIKE ''%etl%date%''     OR c.name LIKE ''%refresh%''
        OR c.name LIKE ''%last%updat%''   OR c.name LIKE ''%updated%''
        OR c.name LIKE ''%modified%''     OR c.name LIKE ''%insert%date%''
        OR c.name LIKE ''%created%date%'' OR c.name LIKE ''%process%date%''
        OR c.name LIKE ''%dw%date%''      OR c.name LIKE ''%valid[_]from%'')
    ORDER BY CASE
        WHEN c.name LIKE ''%load%date%''  THEN 1
        WHEN c.name LIKE ''%etl%date%''   THEN 2
        WHEN c.name LIKE ''%refresh%''    THEN 3
        WHEN c.name LIKE ''%last%updat%'' THEN 4
        WHEN c.name LIKE ''%updated%''    THEN 5
        WHEN c.name LIKE ''%modified%''   THEN 6
        ELSE 7 END, c.column_id
) AS fc
WHERE t.is_ms_shipped = 0
  AND (s.name IN (''mart'',''marts'',''dm'',''datamart'',''dw'',''edw'',''gold'',
                  ''presentation'',''reporting'',''rpt'',''bi'',''star'',''analytics'')
    OR s.name LIKE ''%mart%''
    OR t.name LIKE ''%mart%''
    OR t.name LIKE ''dim[_]%''  OR t.name LIKE ''fact[_]%''
    OR t.name LIKE ''dim%''     OR t.name LIKE ''fact%''
    OR t.name LIKE ''agg[_]%'')';

        INSERT INTO #MartTables (DatabaseName, SchemaName, TableName, FreshnessColumn)
        EXEC sp_executesql @sql, N'@dbname sysname', @dbname = @db;

        SET @sql = N'
SELECT @dbname, s.name + ''.'' + o.name, o.type_desc
FROM ' + QUOTENAME(@db) + N'.sys.objects AS o
INNER JOIN ' + QUOTENAME(@db) + N'.sys.schemas AS s ON s.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0
  AND o.type IN (''U'',''V'',''P'',''FN'',''IF'',''TF'')
  AND (o.name LIKE ''%freshness%''      OR o.name LIKE ''%stale%''
    OR o.name LIKE ''%watermark%''      OR o.name LIKE ''%high[_]water%''
    OR o.name LIKE ''%data[_]quality%'' OR o.name LIKE ''%dataquality%''
    OR o.name LIKE ''%dq[_]%''          OR o.name LIKE ''%load[_]log%''
    OR o.name LIKE ''%etl[_]log%''      OR o.name LIKE ''%load[_]audit%''
    OR o.name LIKE ''%batch[_]control%''OR o.name LIKE ''%last[_]refresh%''
    OR o.name LIKE ''sla[_]%''          OR o.name LIKE ''%[_]sla''
    OR o.name LIKE ''%[_]sla[_]%'')';

        INSERT INTO #Artifacts (DatabaseName, ObjectName, ObjectType)
        EXEC sp_executesql @sql, N'@dbname sysname', @dbname = @db;
    END TRY
    BEGIN CATCH
        /* database unreadable or insufficient permission - skip it */
    END CATCH

    FETCH NEXT FROM db_cur INTO @db;
END

CLOSE db_cur;
DEALLOCATE db_cur;

/* Read the most recent load/refresh timestamp for every trackable mart table */
DECLARE @sdb sysname, @ssch sysname, @stab sysname, @scol sysname;
DECLARE @last datetime2(3);

DECLARE tbl_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName, SchemaName, TableName, FreshnessColumn
    FROM #MartTables
    WHERE FreshnessColumn IS NOT NULL;

OPEN tbl_cur;
FETCH NEXT FROM tbl_cur INTO @sdb, @ssch, @stab, @scol;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @last = NULL;

    BEGIN TRY
        SET @sql = N'SELECT @lastOut = MAX(CONVERT(datetime2(3), ' + QUOTENAME(@scol) + N'))'
                 + N' FROM ' + QUOTENAME(@sdb) + N'.' + QUOTENAME(@ssch) + N'.' + QUOTENAME(@stab)
                 + N' WITH (NOLOCK)';

        EXEC sp_executesql @sql, N'@lastOut datetime2(3) OUTPUT', @lastOut = @last OUTPUT;

        UPDATE #MartTables
        SET LastRefresh = @last
        WHERE DatabaseName = @sdb AND SchemaName = @ssch AND TableName = @stab;
    END TRY
    BEGIN CATCH
        /* table unreadable - leave LastRefresh NULL */
    END CATCH

    FETCH NEXT FROM tbl_cur INTO @sdb, @ssch, @stab, @scol;
END

CLOSE tbl_cur;
DEALLOCATE tbl_cur;

DECLARE @MartCount int = (SELECT COUNT(*) FROM #MartTables);
DECLARE @Trackable int = (SELECT COUNT(*) FROM #MartTables WHERE FreshnessColumn IS NOT NULL);
DECLARE @Measured  int = (SELECT COUNT(*) FROM #MartTables WHERE LastRefresh IS NOT NULL);
DECLARE @Fresh     int = (SELECT COUNT(*) FROM #MartTables
                          WHERE LastRefresh IS NOT NULL
                            AND LastRefresh >= DATEADD(HOUR, -@SlaHours, SYSDATETIME()));
DECLARE @Artifacts int = (SELECT COUNT(*) FROM #Artifacts);
DECLARE @DbCount   int = (SELECT COUNT(*) FROM #Databases);

DECLARE @CoveragePct decimal(5,1) =
    CASE WHEN @MartCount = 0 THEN 0
         ELSE CONVERT(decimal(5,1), 100.0 * @Trackable / @MartCount) END;
DECLARE @FreshPct decimal(5,1) =
    CASE WHEN @Measured = 0 THEN 0
         ELSE CONVERT(decimal(5,1), 100.0 * @Fresh / @Measured) END;

DECLARE @DbList nvarchar(max) =
    ISNULL(STUFF((SELECT N', ' + DatabaseName
                  FROM #Databases
                  ORDER BY DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'None');

DECLARE @StaleList nvarchar(max) =
    ISNULL(STUFF((SELECT TOP (5) N'; ' + DatabaseName + N'.' + SchemaName + N'.' + TableName
                       + N' (last ' + CONVERT(nvarchar(19), LastRefresh, 120) + N')'
                  FROM #MartTables
                  WHERE LastRefresh IS NOT NULL
                    AND LastRefresh < DATEADD(HOUR, -@SlaHours, SYSDATETIME())
                  ORDER BY LastRefresh ASC
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'none');

DECLARE @ArtifactList nvarchar(max) =
    ISNULL(STUFF((SELECT TOP (5) N'; ' + DatabaseName + N'.' + ObjectName + N' (' + ObjectType + N')'
                  FROM #Artifacts
                  ORDER BY DatabaseName, ObjectName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'none');

DECLARE @Score int;

IF @MartCount = 0
    SET @Score = 0;
ELSE IF @Artifacts >= 1 AND @Measured > 0 AND @FreshPct >= 90.0 AND @CoveragePct >= 80.0
    SET @Score = 3;
ELSE IF @Measured > 0 AND @FreshPct >= 70.0
    SET @Score = 2;
ELSE IF @Trackable > 0 OR @Artifacts >= 1
    SET @Score = 1;
ELSE
    SET @Score = 0;

DECLARE @Result nvarchar(20);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DECLARE @Finding nvarchar(max) =
    N'Scanned ' + CONVERT(nvarchar(10), @DbCount) + N' accessible database(s). '
  + CASE WHEN @MartCount = 0
         THEN N'No mart-layer tables (mart/dw/gold/reporting schemas, dim*/fact*/agg_* tables) were identified, so mart freshness against an SLA could not be evidenced; locate the presentation layer and review its refresh SLA manually. '
         ELSE N'Identified ' + CONVERT(nvarchar(10), @MartCount) + N' mart-layer table(s); '
            + CONVERT(nvarchar(10), @Trackable) + N' (' + CONVERT(nvarchar(10), @CoveragePct)
            + N'%) expose a load/refresh timestamp column and ' + CONVERT(nvarchar(10), @Measured)
            + N' returned a value. ' + CONVERT(nvarchar(10), @Fresh) + N' of ' + CONVERT(nvarchar(10), @Measured)
            + N' (' + CONVERT(nvarchar(10), @FreshPct) + N'%) were refreshed within the '
            + CONVERT(nvarchar(10), @SlaHours) + N'-hour default SLA. Oldest breaches: ' + @StaleList + N'. '
    END
  + N'Freshness/SLA monitoring objects found: ' + CONVERT(nvarchar(10), @Artifacts)
  + N' (examples: ' + @ArtifactList + N').';

SELECT
    @Result  AS Result,
    @Score   AS Score,
    @DbList  AS DatabaseQueried,
    @Finding AS Finding;

DROP TABLE #Databases;
DROP TABLE #MartTables;
DROP TABLE #Artifacts;