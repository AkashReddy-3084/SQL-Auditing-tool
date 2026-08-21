/* Checklist 8.3.4 - Metadata accessible to consumers (discoverable)
   Read-only. Measures published description coverage and metadata visibility across databases. */
SET NOCOUNT ON;

DECLARE @IsAzureSqlDb bit =
    CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#MetadataCoverage') IS NOT NULL
    DROP TABLE #MetadataCoverage;

CREATE TABLE #MetadataCoverage
(
    DatabaseName        sysname NOT NULL,
    TotalObjects        int     NULL,
    DocumentedObjects   int     NULL,
    TotalColumns        int     NULL,
    DocumentedColumns   int     NULL,
    MetadataGrantees    int     NULL
);

DECLARE @db  sysname;
DECLARE @sql nvarchar(max);

IF @IsAzureSqlDb = 1
BEGIN
    /* Azure SQL Database: cross-database catalog access is not available. */
    SET @db = DB_NAME();

    INSERT INTO #MetadataCoverage
        (DatabaseName, TotalObjects, DocumentedObjects, TotalColumns, DocumentedColumns, MetadataGrantees)
    SELECT
        @db,
        (SELECT COUNT(*)
           FROM sys.objects o
          WHERE o.type IN ('U','V') AND o.is_ms_shipped = 0),
        (SELECT COUNT(*)
           FROM sys.objects o
          WHERE o.type IN ('U','V') AND o.is_ms_shipped = 0
            AND EXISTS (SELECT 1
                          FROM sys.extended_properties ep
                         WHERE ep.class = 1
                           AND ep.major_id = o.object_id
                           AND ep.minor_id = 0)),
        (SELECT COUNT(*)
           FROM sys.columns c
           INNER JOIN sys.objects o ON o.object_id = c.object_id
          WHERE o.type IN ('U','V') AND o.is_ms_shipped = 0),
        (SELECT COUNT(*)
           FROM sys.columns c
           INNER JOIN sys.objects o ON o.object_id = c.object_id
          WHERE o.type IN ('U','V') AND o.is_ms_shipped = 0
            AND EXISTS (SELECT 1
                          FROM sys.extended_properties ep
                         WHERE ep.class = 1
                           AND ep.major_id = c.object_id
                           AND ep.minor_id = c.column_id)),
        (SELECT COUNT(DISTINCT dp.grantee_principal_id)
           FROM sys.database_permissions dp
           INNER JOIN sys.database_principals pr ON pr.principal_id = dp.grantee_principal_id
          WHERE dp.permission_name = 'VIEW DEFINITION'
            AND dp.state IN ('G','W')
            AND pr.name <> 'dbo');
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
          FROM sys.databases d
         WHERE d.database_id > 4
           AND d.state = 0
           AND d.source_database_id IS NULL
           AND HAS_DBACCESS(d.name) = 1
         ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @sql = N'
SELECT
    @DbName,
    (SELECT COUNT(*)
       FROM ' + QUOTENAME(@db) + N'.sys.objects o
      WHERE o.type IN (''U'',''V'') AND o.is_ms_shipped = 0),
    (SELECT COUNT(*)
       FROM ' + QUOTENAME(@db) + N'.sys.objects o
      WHERE o.type IN (''U'',''V'') AND o.is_ms_shipped = 0
        AND EXISTS (SELECT 1
                      FROM ' + QUOTENAME(@db) + N'.sys.extended_properties ep
                     WHERE ep.class = 1
                       AND ep.major_id = o.object_id
                       AND ep.minor_id = 0)),
    (SELECT COUNT(*)
       FROM ' + QUOTENAME(@db) + N'.sys.columns c
       INNER JOIN ' + QUOTENAME(@db) + N'.sys.objects o ON o.object_id = c.object_id
      WHERE o.type IN (''U'',''V'') AND o.is_ms_shipped = 0),
    (SELECT COUNT(*)
       FROM ' + QUOTENAME(@db) + N'.sys.columns c
       INNER JOIN ' + QUOTENAME(@db) + N'.sys.objects o ON o.object_id = c.object_id
      WHERE o.type IN (''U'',''V'') AND o.is_ms_shipped = 0
        AND EXISTS (SELECT 1
                      FROM ' + QUOTENAME(@db) + N'.sys.extended_properties ep
                     WHERE ep.class = 1
                       AND ep.major_id = c.object_id
                       AND ep.minor_id = c.column_id)),
    (SELECT COUNT(DISTINCT dp.grantee_principal_id)
       FROM ' + QUOTENAME(@db) + N'.sys.database_permissions dp
       INNER JOIN ' + QUOTENAME(@db) + N'.sys.database_principals pr
              ON pr.principal_id = dp.grantee_principal_id
      WHERE dp.permission_name = ''VIEW DEFINITION''
        AND dp.state IN (''G'',''W'')
        AND pr.name <> ''dbo'');';

            INSERT INTO #MetadataCoverage
                (DatabaseName, TotalObjects, DocumentedObjects, TotalColumns, DocumentedColumns, MetadataGrantees)
            EXEC sp_executesql @sql, N'@DbName sysname', @DbName = @db;
        END TRY
        BEGIN CATCH
            INSERT INTO #MetadataCoverage (DatabaseName) VALUES (@db);
        END CATCH

        FETCH NEXT FROM db_cursor INTO @db;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

IF OBJECT_ID('tempdb..#MetadataScored') IS NOT NULL
    DROP TABLE #MetadataScored;

CREATE TABLE #MetadataScored
(
    DatabaseName        sysname       NOT NULL,
    TotalObjects        int           NULL,
    DocumentedObjects   int           NULL,
    TotalColumns        int           NULL,
    DocumentedColumns   int           NULL,
    MetadataGrantees    int           NULL,
    ObjPct              decimal(5,1)  NULL,
    ColPct              decimal(5,1)  NULL,
    DbState             varchar(20)   NOT NULL
);

INSERT INTO #MetadataScored
    (DatabaseName, TotalObjects, DocumentedObjects, TotalColumns, DocumentedColumns,
     MetadataGrantees, ObjPct, ColPct, DbState)
SELECT
    m.DatabaseName,
    m.TotalObjects,
    m.DocumentedObjects,
    m.TotalColumns,
    m.DocumentedColumns,
    m.MetadataGrantees,
    x.ObjPct,
    x.ColPct,
    CASE
        WHEN m.TotalObjects IS NULL THEN 'Unreadable'
        WHEN m.TotalObjects = 0 THEN 'NoUserObjects'
        WHEN x.ObjPct >= 80.0 AND ISNULL(x.ColPct, 0) >= 50.0 THEN 'Compliant'
        WHEN x.ObjPct >= 50.0 THEN 'Partial'
        ELSE 'NonCompliant'
    END
FROM #MetadataCoverage m
CROSS APPLY
(
    SELECT
        ObjPct = CASE WHEN ISNULL(m.TotalObjects, 0) = 0 THEN NULL
                      ELSE CONVERT(decimal(5,1), 100.0 * m.DocumentedObjects / m.TotalObjects) END,
        ColPct = CASE WHEN ISNULL(m.TotalColumns, 0) = 0 THEN NULL
                      ELSE CONVERT(decimal(5,1), 100.0 * m.DocumentedColumns / m.TotalColumns) END
) x;

DECLARE @DbTotal        int = (SELECT COUNT(*) FROM #MetadataScored);
DECLARE @DbUnreadable   int = (SELECT COUNT(*) FROM #MetadataScored WHERE DbState = 'Unreadable');
DECLARE @DbEmpty        int = (SELECT COUNT(*) FROM #MetadataScored WHERE DbState = 'NoUserObjects');
DECLARE @DbCompliant    int = (SELECT COUNT(*) FROM #MetadataScored WHERE DbState = 'Compliant');
DECLARE @DbPartial      int = (SELECT COUNT(*) FROM #MetadataScored WHERE DbState = 'Partial');
DECLARE @DbNonCompliant int = (SELECT COUNT(*) FROM #MetadataScored WHERE DbState = 'NonCompliant');
DECLARE @DbMeasured     int = @DbCompliant + @DbPartial + @DbNonCompliant;
DECLARE @DbQualified    int = @DbMeasured + @DbUnreadable;

DECLARE @SumObjects     bigint = (SELECT ISNULL(SUM(CONVERT(bigint, TotalObjects)), 0)      FROM #MetadataScored);
DECLARE @SumObjectsDoc  bigint = (SELECT ISNULL(SUM(CONVERT(bigint, DocumentedObjects)), 0) FROM #MetadataScored);
DECLARE @SumColumns     bigint = (SELECT ISNULL(SUM(CONVERT(bigint, TotalColumns)), 0)      FROM #MetadataScored);
DECLARE @SumColumnsDoc  bigint = (SELECT ISNULL(SUM(CONVERT(bigint, DocumentedColumns)), 0) FROM #MetadataScored);
DECLARE @SumGrantees    bigint = (SELECT ISNULL(SUM(CONVERT(bigint, MetadataGrantees)), 0)  FROM #MetadataScored);

DECLARE @OverallObjPct decimal(5,1) =
    CASE WHEN @SumObjects = 0 THEN NULL
         ELSE CONVERT(decimal(5,1), 100.0 * @SumObjectsDoc / @SumObjects) END;
DECLARE @OverallColPct decimal(5,1) =
    CASE WHEN @SumColumns = 0 THEN NULL
         ELSE CONVERT(decimal(5,1), 100.0 * @SumColumnsDoc / @SumColumns) END;

DECLARE @ProblemList nvarchar(max) =
    STUFF((SELECT N', ' + s.DatabaseName + N' (' + CONVERT(nvarchar(10), ISNULL(s.ObjPct, 0)) + N'%)'
             FROM #MetadataScored s
            WHERE s.DbState IN ('Partial','NonCompliant')
            ORDER BY s.ObjPct, s.DatabaseName
              FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

DECLARE @UnreadableList nvarchar(max) =
    STUFF((SELECT N', ' + s.DatabaseName
             FROM #MetadataScored s
            WHERE s.DbState = 'Unreadable'
            ORDER BY s.DatabaseName
              FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

DECLARE @Result          nvarchar(20);
DECLARE @Score           int;
DECLARE @DatabaseQueried nvarchar(128);
DECLARE @Finding         nvarchar(max);

IF @DbQualified = 0
BEGIN
    /* No accessible online user database holds user tables or views. */
    SET @Score           = 0;
    SET @DatabaseQueried = N'None';
    SET @Finding         = N'No database found to be queried';
END
ELSE
BEGIN
    SET @Score =
        CASE
            WHEN @DbMeasured = 0 THEN 1
            WHEN @DbCompliant = @DbMeasured AND @DbUnreadable = 0 THEN 3
            WHEN @DbNonCompliant = 0 AND @DbUnreadable = 0 THEN 2
            WHEN @SumObjectsDoc > 0 THEN 1
            ELSE 0
        END;

    SET @DatabaseQueried =
        CASE
            WHEN @DbTotal = 1 THEN (SELECT TOP (1) CONVERT(nvarchar(128), DatabaseName) FROM #MetadataScored)
            ELSE CONVERT(nvarchar(128), CONCAT(N'ALL USER DATABASES (', @DbTotal, N')'))
        END;

    SET @Finding =
        CASE
            WHEN @DbMeasured = 0
                THEN CONCAT(N'Catalog metadata could not be read for ', @DbUnreadable,
                            N' database(s): ', @UnreadableList,
                            N'. Metadata discoverability could not be confirmed.')
            ELSE CONCAT(
                    N'Measured ', @DbMeasured, N' database(s) holding user objects (',
                    @DbEmpty, N' empty, ', @DbUnreadable, N' unreadable). ',
                    N'Described tables/views: ', @SumObjectsDoc, N' of ', @SumObjects,
                    N' (', ISNULL(@OverallObjPct, 0), N'%). Described columns: ', @SumColumnsDoc, N' of ', @SumColumns,
                    N' (', ISNULL(@OverallColPct, 0), N'%). Fully documented databases: ', @DbCompliant,
                    N' of ', @DbMeasured, N'. Principals granted VIEW DEFINITION: ', @SumGrantees, N'.',
                    CASE WHEN @ProblemList IS NOT NULL
                         THEN CONCAT(N' Below-target databases (object description coverage): ', @ProblemList, N'.')
                         ELSE N'' END,
                    CASE WHEN @UnreadableList IS NOT NULL
                         THEN CONCAT(N' Unreadable databases: ', @UnreadableList, N'.')
                         ELSE N'' END,
                    N' Descriptions are read from extended properties, the in-engine data dictionary consumers can query.')
        END;
END

SET @Result = CASE WHEN @Score = 3 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#MetadataCoverage') IS NOT NULL
    DROP TABLE #MetadataCoverage;
IF OBJECT_ID('tempdb..#MetadataScored') IS NOT NULL
    DROP TABLE #MetadataScored;