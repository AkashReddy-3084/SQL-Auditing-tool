/*
    Checklist Item : 5.3.5 - Cross-layer reconciliation (mart vs integration vs source counts)
    Scope          : DATABASE (all accessible online user databases)
    Type           : Read-only metadata inspection (catalog views only)
    Output         : Result, Score, DatabaseQueried, Finding
*/
SET NOCOUNT ON;

DECLARE @Result          NVARCHAR(50),
        @Score           INT,
        @DatabaseQueried NVARCHAR(MAX),
        @Finding         NVARCHAR(MAX);

DECLARE @IsSingleDbEngine BIT =
        CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) IN (5, 6, 11) THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#Db') IS NOT NULL DROP TABLE #Db;
IF OBJECT_ID('tempdb..#Layer') IS NOT NULL DROP TABLE #Layer;
IF OBJECT_ID('tempdb..#Recon') IS NOT NULL DROP TABLE #Recon;
IF OBJECT_ID('tempdb..#ReconTable') IS NOT NULL DROP TABLE #ReconTable;
IF OBJECT_ID('tempdb..#Summary') IS NOT NULL DROP TABLE #Summary;

CREATE TABLE #Db         (DatabaseName SYSNAME PRIMARY KEY, ScanError NVARCHAR(400) NULL);
CREATE TABLE #Layer      (DatabaseName SYSNAME, LayerObject NVARCHAR(300), Category VARCHAR(20));
CREATE TABLE #Recon      (DatabaseName SYSNAME, ObjectType NVARCHAR(60), SchemaName SYSNAME, ObjectName SYSNAME);
CREATE TABLE #ReconTable (DatabaseName SYSNAME, SchemaName SYSNAME, TableName SYSNAME, RowCnt BIGINT);

IF @IsSingleDbEngine = 1
    INSERT INTO #Db (DatabaseName) SELECT DB_NAME();
ELSE
    INSERT INTO #Db (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state_desc = 'ONLINE'
      AND d.source_database_id IS NULL
      AND d.is_in_standby = 0
      AND HAS_DBACCESS(d.name) = 1;

DECLARE @db SYSNAME, @pfx NVARCHAR(300), @sql NVARCHAR(MAX), @err NVARCHAR(400);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Db;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @pfx = CASE WHEN @IsSingleDbEngine = 1 THEN N'' ELSE QUOTENAME(@db) + N'.' END;

    BEGIN TRY
        /* Layer detection: dedicated layer schemas that actually hold tables, plus layer table-name prefixes. */
        SET @sql = N'
        SELECT @pDb, CAST(s.name AS NVARCHAR(300)), x.Category
        FROM ' + @pfx + N'sys.schemas AS s
        CROSS APPLY (SELECT CASE
                WHEN LOWER(s.name) IN (''mart'',''marts'',''datamart'',''datamarts'',''dm'',''presentation'',''gold'',''curated'',''semantic'',''reporting'') THEN ''MART''
                WHEN LOWER(s.name) IN (''integration'',''integ'',''core'',''conformed'',''silver'',''edw'',''dw'',''ods'',''transform'',''warehouse'') THEN ''INTEGRATION''
                WHEN LOWER(s.name) IN (''source'',''src'',''raw'',''stage'',''staging'',''stg'',''landing'',''bronze'',''ingest'',''extract'') THEN ''SOURCE''
                END) AS x(Category)
        WHERE x.Category IS NOT NULL
          AND EXISTS (SELECT 1 FROM ' + @pfx + N'sys.tables AS t
                      WHERE t.schema_id = s.schema_id AND t.is_ms_shipped = 0)
        UNION
        SELECT @pDb, CAST(N''table prefix: '' + LEFT(t2.name, 12) AS NVARCHAR(300)), y.Category
        FROM ' + @pfx + N'sys.tables AS t2
        CROSS APPLY (SELECT CASE
                WHEN LOWER(t2.name) LIKE ''mart[_]%'' OR LOWER(t2.name) LIKE ''dm[_]%'' OR LOWER(t2.name) LIKE ''gold[_]%'' THEN ''MART''
                WHEN LOWER(t2.name) LIKE ''int[_]%'' OR LOWER(t2.name) LIKE ''dw[_]%'' OR LOWER(t2.name) LIKE ''ods[_]%'' OR LOWER(t2.name) LIKE ''silver[_]%'' THEN ''INTEGRATION''
                WHEN LOWER(t2.name) LIKE ''stg[_]%'' OR LOWER(t2.name) LIKE ''stage[_]%'' OR LOWER(t2.name) LIKE ''src[_]%'' OR LOWER(t2.name) LIKE ''raw[_]%'' OR LOWER(t2.name) LIKE ''bronze[_]%'' THEN ''SOURCE''
                END) AS y(Category)
        WHERE y.Category IS NOT NULL
          AND t2.is_ms_shipped = 0;';

        INSERT INTO #Layer (DatabaseName, LayerObject, Category)
        EXEC sp_executesql @sql, N'@pDb SYSNAME', @pDb = @db;

        /* Reconciliation logic: modules named for, or written to perform, cross-layer count comparison. */
        SET @sql = N'
        SELECT @pDb, o.type_desc, s.name, o.name
        FROM ' + @pfx + N'sys.objects AS o
        INNER JOIN ' + @pfx + N'sys.schemas AS s ON s.schema_id = o.schema_id
        LEFT JOIN ' + @pfx + N'sys.sql_modules AS m ON m.object_id = o.object_id
        WHERE o.is_ms_shipped = 0
          AND o.type IN (''P'',''V'',''FN'',''IF'',''TF'')
          AND ( LOWER(o.name) LIKE ''%recon%''
             OR LOWER(o.name) LIKE ''%rowcount%''
             OR LOWER(o.name) LIKE ''%row[_]count%''
             OR LOWER(o.name) LIKE ''%countcheck%''
             OR LOWER(o.name) LIKE ''%count[_]check%''
             OR LOWER(o.name) LIKE ''%countcompare%''
             OR LOWER(o.name) LIKE ''%crosslayer%''
             OR LOWER(o.name) LIKE ''%cross[_]layer%''
             OR LOWER(m.definition) LIKE ''%reconcil%''
             OR ( LOWER(m.definition) LIKE ''%count(*)%''
                  AND ( LOWER(m.definition) LIKE ''%sourcecount%''
                     OR LOWER(m.definition) LIKE ''%source[_]count%''
                     OR LOWER(m.definition) LIKE ''%targetcount%''
                     OR LOWER(m.definition) LIKE ''%target[_]count%'' ) ) );';

        INSERT INTO #Recon (DatabaseName, ObjectType, SchemaName, ObjectName)
        EXEC sp_executesql @sql, N'@pDb SYSNAME', @pDb = @db;

        /* Retained reconciliation results: reconciliation tables carrying count/variance columns, with their row counts. */
        SET @sql = N'
        SELECT @pDb, s.name, t.name, ISNULL(p.RowCnt, 0)
        FROM ' + @pfx + N'sys.tables AS t
        INNER JOIN ' + @pfx + N'sys.schemas AS s ON s.schema_id = t.schema_id
        OUTER APPLY (SELECT SUM(pa.rows) AS RowCnt
                     FROM ' + @pfx + N'sys.partitions AS pa
                     WHERE pa.object_id = t.object_id AND pa.index_id IN (0, 1)) AS p
        WHERE t.is_ms_shipped = 0
          AND ( LOWER(t.name) LIKE ''%recon%''
             OR LOWER(t.name) LIKE ''%rowcount%''
             OR LOWER(t.name) LIKE ''%row[_]count%''
             OR LOWER(t.name) LIKE ''%countcheck%''
             OR LOWER(t.name) LIKE ''%count[_]check%''
             OR LOWER(t.name) LIKE ''%countcompare%''
             OR LOWER(t.name) LIKE ''%crosslayer%''
             OR LOWER(t.name) LIKE ''%cross[_]layer%'' )
          AND EXISTS (SELECT 1 FROM ' + @pfx + N'sys.columns AS c
                      WHERE c.object_id = t.object_id
                        AND ( LOWER(c.name) LIKE ''%count%''
                           OR LOWER(c.name) LIKE ''%rows%''
                           OR LOWER(c.name) LIKE ''%diff%''
                           OR LOWER(c.name) LIKE ''%variance%''
                           OR LOWER(c.name) LIKE ''%layer%''
                           OR LOWER(c.name) LIKE ''%source%'' ));';

        INSERT INTO #ReconTable (DatabaseName, SchemaName, TableName, RowCnt)
        EXEC sp_executesql @sql, N'@pDb SYSNAME', @pDb = @db;
    END TRY
    BEGIN CATCH
        SET @err = LEFT(ERROR_MESSAGE(), 400);
        UPDATE #Db SET ScanError = @err WHERE DatabaseName = @db;
    END CATCH;

    FETCH NEXT FROM db_cur INTO @db;
END

CLOSE db_cur;
DEALLOCATE db_cur;

IF NOT EXISTS (SELECT 1 FROM #Db)
    INSERT INTO #Db (DatabaseName, ScanError)
    VALUES (N'N/A', N'No accessible online user database was found on this instance.');

SELECT
    d.DatabaseName,
    d.ScanError,
    LayerCats = (SELECT COUNT(DISTINCT l.Category) FROM #Layer AS l WHERE l.DatabaseName = d.DatabaseName),
    ReconObjCount = (SELECT COUNT(*) FROM #Recon AS r WHERE r.DatabaseName = d.DatabaseName),
    ReconTblCount = (SELECT COUNT(*) FROM #ReconTable AS t WHERE t.DatabaseName = d.DatabaseName),
    ReconTblRows  = (SELECT ISNULL(SUM(t2.RowCnt), 0) FROM #ReconTable AS t2 WHERE t2.DatabaseName = d.DatabaseName)
INTO #Summary
FROM #Db AS d;

DECLARE @TotalDbs        INT,
        @LayeredDbs      INT,
        @FullReconDbs    INT,
        @PartialReconDbs INT,
        @GapDbs          INT,
        @ErrorDbs        INT;

SELECT
    @TotalDbs        = COUNT(*),
    @LayeredDbs      = SUM(CASE WHEN s.ScanError IS NULL AND s.LayerCats >= 2 THEN 1 ELSE 0 END),
    @FullReconDbs    = SUM(CASE WHEN s.ScanError IS NULL AND s.ReconObjCount > 0 AND s.ReconTblRows > 0 THEN 1 ELSE 0 END),
    @PartialReconDbs = SUM(CASE WHEN s.ScanError IS NULL
                                 AND (s.ReconObjCount > 0 OR s.ReconTblCount > 0)
                                 AND NOT (s.ReconObjCount > 0 AND s.ReconTblRows > 0) THEN 1 ELSE 0 END),
    @GapDbs          = SUM(CASE WHEN s.ScanError IS NULL AND s.LayerCats >= 2
                                 AND s.ReconObjCount = 0 AND s.ReconTblCount = 0 THEN 1 ELSE 0 END),
    @ErrorDbs        = SUM(CASE WHEN s.ScanError IS NOT NULL THEN 1 ELSE 0 END),
    @Score           = MIN(CASE
                             WHEN s.ScanError IS NOT NULL THEN 2
                             WHEN s.ReconObjCount > 0 AND s.ReconTblRows > 0 THEN 3
                             WHEN s.ReconObjCount > 0 OR s.ReconTblCount > 0 THEN 2
                             WHEN s.LayerCats >= 2 THEN 1
                             ELSE 2
                           END)
FROM #Summary AS s;

SET @Score = ISNULL(@Score, 2);

SET @Result = CASE
                WHEN @Score = 3 THEN N'Pass'
                WHEN @Score = 1 THEN N'Fail'
                WHEN @LayeredDbs = 0 AND (@FullReconDbs + @PartialReconDbs) = 0 THEN N'Manual Review'
                ELSE N'Partial'
              END;

SELECT @DatabaseQueried = ISNULL(STUFF((SELECT N', ' + s.DatabaseName
                                        FROM #Summary AS s
                                        ORDER BY s.DatabaseName
                                        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'N/A');

DECLARE @GapList   NVARCHAR(MAX),
        @GoodList  NVARCHAR(MAX),
        @PartList  NVARCHAR(MAX),
        @ErrList   NVARCHAR(MAX);

SELECT @GapList = ISNULL(STUFF((SELECT TOP (10) N', ' + s.DatabaseName
                                FROM #Summary AS s
                                WHERE s.ScanError IS NULL AND s.LayerCats >= 2
                                  AND s.ReconObjCount = 0 AND s.ReconTblCount = 0
                                ORDER BY s.DatabaseName
                                FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'none');

SELECT @GoodList = ISNULL(STUFF((SELECT TOP (10) N', ' + s.DatabaseName
                                 FROM #Summary AS s
                                 WHERE s.ScanError IS NULL AND s.ReconObjCount > 0 AND s.ReconTblRows > 0
                                 ORDER BY s.DatabaseName
                                 FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'none');

SELECT @PartList = ISNULL(STUFF((SELECT TOP (10) N', ' + s.DatabaseName
                                 FROM #Summary AS s
                                 WHERE s.ScanError IS NULL
                                   AND (s.ReconObjCount > 0 OR s.ReconTblCount > 0)
                                   AND NOT (s.ReconObjCount > 0 AND s.ReconTblRows > 0)
                                 ORDER BY s.DatabaseName
                                 FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'none');

SELECT @ErrList = ISNULL(STUFF((SELECT TOP (10) N', ' + s.DatabaseName
                                FROM #Summary AS s
                                WHERE s.ScanError IS NOT NULL
                                ORDER BY s.DatabaseName
                                FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'none');

SET @Finding =
      N'Databases inspected: ' + CAST(@TotalDbs AS NVARCHAR(10))
    + N'. Databases exposing 2 or more distinct data layers (mart / integration / source): ' + CAST(@LayeredDbs AS NVARCHAR(10))
    + N'. Databases with cross-layer reconciliation logic AND retained reconciliation results: ' + CAST(@FullReconDbs AS NVARCHAR(10))
    + N' (' + @GoodList + N')'
    + N'. Databases with reconciliation artifacts but no retained results: ' + CAST(@PartialReconDbs AS NVARCHAR(10))
    + N' (' + @PartList + N')'
    + N'. Layered databases with no reconciliation logic or result tables: ' + CAST(@GapDbs AS NVARCHAR(10))
    + N' (' + @GapList + N')'
    + CASE WHEN @ErrorDbs > 0
           THEN N'. Databases whose metadata could not be read: ' + CAST(@ErrorDbs AS NVARCHAR(10)) + N' (' + @ErrList + N')'
           ELSE N'' END
    + CASE
        WHEN @Score = 3
            THEN N'. Every inspected database that holds data compares counts across layers and retains the reconciliation output.'
        WHEN @Score = 1
            THEN N'. At least one multi-layer database compares no counts between its mart, integration and source layers, so silent load loss would go undetected.'
        WHEN @Result = N'Manual Review'
            THEN N'. No multi-layer (mart / integration / source) model and no reconciliation artifacts were detected, so cross-layer reconciliation may not apply here; confirm the platform design manually.'
        ELSE N'. Reconciliation artifacts were found but coverage is incomplete or no reconciliation results are retained, so successful cross-layer count matching cannot be evidenced.'
      END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

DROP TABLE #Summary;
DROP TABLE #ReconTable;
DROP TABLE #Recon;
DROP TABLE #Layer;
DROP TABLE #Db;