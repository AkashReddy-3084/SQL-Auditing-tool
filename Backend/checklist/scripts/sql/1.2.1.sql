/*
    Checklist Item : 1.2.1 - Clear layering defined (staging -> ODS/integration -> dimensional DW -> data marts)
    Scope          : DATABASE
    Type           : Read-only catalog-view proxy (sys.databases / sys.schemas / sys.objects); only #temp tables are written.
*/
SET NOCOUNT ON;

DECLARE @Result          nvarchar(20);
DECLARE @Score           int;
DECLARE @DatabaseQueried nvarchar(max);
DECLARE @Finding         nvarchar(max);

IF OBJECT_ID('tempdb..#Db') IS NOT NULL DROP TABLE #Db;
IF OBJECT_ID('tempdb..#LayerEvidence') IS NOT NULL DROP TABLE #LayerEvidence;

CREATE TABLE #Db
(
    DatabaseName    sysname NOT NULL PRIMARY KEY,
    UserObjectCount int     NOT NULL CONSTRAINT DF_Db_ObjCount   DEFAULT (0),
    Accessible      bit     NOT NULL CONSTRAINT DF_Db_Accessible DEFAULT (1)
);

CREATE TABLE #LayerEvidence
(
    DatabaseName  sysname       NOT NULL,
    LayerName     varchar(30)   NOT NULL,
    EvidenceCount int           NOT NULL,
    SampleObject  nvarchar(400) NULL
);

DECLARE @IsAzureSqlDb bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;

IF @IsAzureSqlDb = 1
BEGIN
    INSERT INTO #Db (DatabaseName)
    SELECT DB_NAME();
END
ELSE
BEGIN
    INSERT INTO #Db (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0                  -- ONLINE only
      AND d.source_database_id IS NULL -- exclude database snapshots
      AND d.name NOT IN (N'distribution', N'SSISDB', N'ReportServer', N'ReportServerTempDB')
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @Template nvarchar(max) = N'
INSERT INTO #LayerEvidence (DatabaseName, LayerName, EvidenceCount, SampleObject)
SELECT N''@@DBLIT@@'',
       L.LayerName,
       COUNT(*),
       MAX(s.name + N''.'' + o.name)
FROM @@PREFIX@@sys.objects AS o
INNER JOIN @@PREFIX@@sys.schemas AS s
        ON s.schema_id = o.schema_id
CROSS APPLY (
    SELECT CASE
        WHEN LOWER(s.name) IN (N''stg'', N''stage'', N''staging'', N''land'', N''landing'', N''raw'', N''src'', N''source'', N''extract'', N''import'', N''ingest'', N''bronze'')
             OR LOWER(o.name) LIKE N''stg[_]%''
             OR LOWER(o.name) LIKE N''stage[_]%''
             OR LOWER(o.name) LIKE N''staging[_]%''
             OR LOWER(o.name) LIKE N''raw[_]%''
             OR LOWER(o.name) LIKE N''land[_]%''
            THEN ''Staging''
        WHEN LOWER(s.name) IN (N''ods'', N''int'', N''integration'', N''core'', N''base'', N''hub'', N''conformed'', N''persist'', N''psa'', N''silver'')
             OR LOWER(o.name) LIKE N''ods[_]%''
             OR LOWER(o.name) LIKE N''int[_]%''
             OR LOWER(o.name) LIKE N''hub[_]%''
             OR LOWER(o.name) LIKE N''lnk[_]%''
             OR LOWER(o.name) LIKE N''sat[_]%''
            THEN ''ODS/Integration''
        WHEN LOWER(s.name) IN (N''dw'', N''dwh'', N''edw'', N''warehouse'', N''dimensional'', N''star'', N''dim'', N''fact'', N''gold'')
             OR LOWER(o.name) LIKE N''dim[_]%''
             OR LOWER(o.name) LIKE N''fact[_]%''
             OR LOWER(o.name) LIKE N''factless[_]%''
            THEN ''Dimensional DW''
        WHEN LOWER(s.name) IN (N''mart'', N''marts'', N''datamart'', N''dm'', N''rpt'', N''report'', N''reporting'', N''semantic'', N''cube'', N''analytics'', N''bi'', N''presentation'', N''pres'')
             OR LOWER(o.name) LIKE N''mart[_]%''
             OR LOWER(o.name) LIKE N''rpt[_]%''
             OR LOWER(o.name) LIKE N''agg[_]%''
            THEN ''Data Mart''
        ELSE NULL
    END AS LayerName
) AS L
WHERE o.is_ms_shipped = 0
  AND o.type IN (''U'', ''V'')
  AND s.name NOT IN (N''sys'', N''INFORMATION_SCHEMA'')
  AND L.LayerName IS NOT NULL
GROUP BY L.LayerName;

UPDATE #Db
SET UserObjectCount = (
        SELECT COUNT(*)
        FROM @@PREFIX@@sys.objects AS o2
        INNER JOIN @@PREFIX@@sys.schemas AS s2
                ON s2.schema_id = o2.schema_id
        WHERE o2.is_ms_shipped = 0
          AND o2.type IN (''U'', ''V'')
          AND s2.name NOT IN (N''sys'', N''INFORMATION_SCHEMA'')
    )
WHERE DatabaseName = N''@@DBLIT@@'';
';

DECLARE @DbName sysname, @Prefix nvarchar(300), @DbLit nvarchar(300), @Sql nvarchar(max);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Db ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Prefix = CASE WHEN @IsAzureSqlDb = 1 THEN N'' ELSE QUOTENAME(@DbName) + N'.' END;
    SET @DbLit  = REPLACE(@DbName, N'''', N'''''');
    SET @Sql    = REPLACE(REPLACE(@Template, N'@@PREFIX@@', @Prefix), N'@@DBLIT@@', @DbLit);

    BEGIN TRY
        EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        UPDATE #Db SET Accessible = 0 WHERE DatabaseName = @DbName;
    END CATCH;

    FETCH NEXT FROM db_cur INTO @DbName;
END

CLOSE db_cur;
DEALLOCATE db_cur;

DECLARE @Assessed int, @Compliant int, @TwoLayer int, @Inaccessible int;

SELECT @Assessed     = ISNULL(SUM(CASE WHEN x.Accessible = 1 THEN 1 ELSE 0 END), 0),
       @Compliant    = ISNULL(SUM(CASE WHEN x.Accessible = 1 AND x.LayerCount >= 3 THEN 1 ELSE 0 END), 0),
       @TwoLayer     = ISNULL(SUM(CASE WHEN x.Accessible = 1 AND x.LayerCount = 2 THEN 1 ELSE 0 END), 0),
       @Inaccessible = ISNULL(SUM(CASE WHEN x.Accessible = 0 THEN 1 ELSE 0 END), 0)
FROM (
    SELECT d.Accessible,
           (SELECT COUNT(DISTINCT le.LayerName)
            FROM #LayerEvidence AS le
            WHERE le.DatabaseName = d.DatabaseName) AS LayerCount
    FROM #Db AS d
) AS x;

SET @Assessed     = ISNULL(@Assessed, 0);
SET @Compliant    = ISNULL(@Compliant, 0);
SET @TwoLayer     = ISNULL(@TwoLayer, 0);
SET @Inaccessible = ISNULL(@Inaccessible, 0);

DECLARE @Detail nvarchar(max) =
    ISNULL(STUFF((
        SELECT N' | ' + d.DatabaseName + N': '
               + CAST((SELECT COUNT(DISTINCT le2.LayerName)
                       FROM #LayerEvidence AS le2
                       WHERE le2.DatabaseName = d.DatabaseName) AS nvarchar(10)) + N'/4 layer(s)'
               + ISNULL(N' [' + f.LayerList + N']', N' [none]')
               + N', ' + CAST(d.UserObjectCount AS nvarchar(10)) + N' user tables/views'
               + CASE WHEN d.Accessible = 0 THEN N' (metadata unreadable)' ELSE N'' END
        FROM #Db AS d
        OUTER APPLY (
            SELECT STUFF((
                SELECT N'; ' + le.LayerName + N' (' + CAST(le.EvidenceCount AS nvarchar(10)) + N' objects, e.g. ' + le.SampleObject + N')'
                FROM #LayerEvidence AS le
                WHERE le.DatabaseName = d.DatabaseName
                ORDER BY le.LayerName
                FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'') AS LayerList
        ) AS f
        ORDER BY d.DatabaseName
        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 3, N''), N'');

IF @Assessed = 0
BEGIN
    SET @DatabaseQueried = 'None';
    SET @Finding = 'No database found to be queried';
    SET @Score = 0;
END
ELSE
BEGIN
    SET @DatabaseQueried = ISNULL(LEFT(STUFF((
            SELECT N', ' + d.DatabaseName
            FROM #Db AS d
            WHERE d.Accessible = 1
            ORDER BY d.DatabaseName
            FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), 1000), 'None');

    IF @Compliant = @Assessed
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'All ' + CAST(@Assessed AS nvarchar(10)) + N' assessed database(s) expose 3 or more distinct warehouse layers through schema and object naming. Detail: ' + @Detail + N'.';
    END
    ELSE IF @Compliant > 0
    BEGIN
        SET @Score   = 2;
        SET @Finding = N'Only ' + CAST(@Compliant AS nvarchar(10)) + N' of ' + CAST(@Assessed AS nvarchar(10))
                     + N' assessed database(s) expose 3 or more distinct warehouse layers; the remainder show a flat or partially layered structure. Detail: ' + @Detail + N'.';
    END
    ELSE IF @TwoLayer > 0
    BEGIN
        SET @Score   = 1;
        SET @Finding = N'No assessed database exposes 3 or more warehouse layers; ' + CAST(@TwoLayer AS nvarchar(10))
                     + N' database(s) show only 2 layers, so staging, ODS/integration, dimensional DW and data mart concerns are not separated. Detail: ' + @Detail + N'.';
    END
    ELSE
    BEGIN
        SET @Score   = 0;
        SET @Finding = N'No layering convention was detected in any of the ' + CAST(@Assessed AS nvarchar(10))
                     + N' assessed database(s): schema and object names show no evidence of staging, ODS/integration, dimensional DW or data mart layers. Detail: ' + @Detail + N'.';
    END

    IF @Inaccessible > 0
        SET @Finding = @Finding + N' ' + CAST(@Inaccessible AS nvarchar(10)) + N' database(s) could not be read and were excluded from scoring.';

    SET @Finding = LEFT(@Finding, 3900);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;