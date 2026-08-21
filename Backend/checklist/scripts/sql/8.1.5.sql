SET NOCOUNT ON;

DECLARE @Result nvarchar(20);
DECLARE @Score int;
DECLARE @DatabaseQueried nvarchar(max);
DECLARE @Finding nvarchar(max);
DECLARE @Details nvarchar(max);

DECLARE @IsAzureDb bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#DocCoverage') IS NOT NULL DROP TABLE #DocCoverage;
CREATE TABLE #DocCoverage
(
    DatabaseName            sysname NOT NULL,
    TableCount              int NOT NULL,
    DocumentedTables        int NOT NULL,
    ColumnCount             int NOT NULL,
    DocumentedColumns       int NOT NULL,
    ProgrammableCount       int NOT NULL,
    DocumentedProgrammable  int NOT NULL
);

IF OBJECT_ID('tempdb..#Targets') IS NOT NULL DROP TABLE #Targets;
CREATE TABLE #Targets (DatabaseName sysname NOT NULL PRIMARY KEY);

IF @IsAzureDb = 1
BEGIN
    INSERT INTO #Targets (DatabaseName)
    SELECT DB_NAME();
END
ELSE
BEGIN
    INSERT INTO #Targets (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.name NOT IN ('master', 'model', 'msdb', 'tempdb')
      AND d.state_desc = 'ONLINE'
      AND d.is_read_only = 0
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @db sysname, @prefix nvarchar(300), @sql nvarchar(max);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Targets ORDER BY DatabaseName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @prefix = CASE WHEN @IsAzureDb = 1 THEN N'' ELSE QUOTENAME(@db) + N'.' END;

    SET @sql = N'
SELECT
    @dbName,
    (SELECT COUNT(*)
       FROM ' + @prefix + N'sys.tables AS t
      WHERE t.is_ms_shipped = 0),
    (SELECT COUNT(*)
       FROM ' + @prefix + N'sys.tables AS t
      WHERE t.is_ms_shipped = 0
        AND EXISTS (SELECT 1
                      FROM ' + @prefix + N'sys.extended_properties AS ep
                     WHERE ep.class = 1
                       AND ep.major_id = t.object_id
                       AND ep.minor_id = 0
                       AND ep.name = ''MS_Description'')),
    (SELECT COUNT(*)
       FROM ' + @prefix + N'sys.columns AS c
       JOIN ' + @prefix + N'sys.tables AS t2 ON t2.object_id = c.object_id
      WHERE t2.is_ms_shipped = 0),
    (SELECT COUNT(*)
       FROM ' + @prefix + N'sys.columns AS c
       JOIN ' + @prefix + N'sys.tables AS t2 ON t2.object_id = c.object_id
      WHERE t2.is_ms_shipped = 0
        AND EXISTS (SELECT 1
                      FROM ' + @prefix + N'sys.extended_properties AS ep
                     WHERE ep.class = 1
                       AND ep.major_id = c.object_id
                       AND ep.minor_id = c.column_id
                       AND ep.name = ''MS_Description'')),
    (SELECT COUNT(*)
       FROM ' + @prefix + N'sys.objects AS o
      WHERE o.is_ms_shipped = 0
        AND o.type IN (''P'', ''V'', ''FN'', ''IF'', ''TF'')),
    (SELECT COUNT(*)
       FROM ' + @prefix + N'sys.objects AS o
      WHERE o.is_ms_shipped = 0
        AND o.type IN (''P'', ''V'', ''FN'', ''IF'', ''TF'')
        AND EXISTS (SELECT 1
                      FROM ' + @prefix + N'sys.extended_properties AS ep
                     WHERE ep.class = 1
                       AND ep.major_id = o.object_id
                       AND ep.minor_id = 0
                       AND ep.name = ''MS_Description''));';

    BEGIN TRY
        INSERT INTO #DocCoverage
            (DatabaseName, TableCount, DocumentedTables, ColumnCount, DocumentedColumns, ProgrammableCount, DocumentedProgrammable)
        EXEC sp_executesql @sql, N'@dbName sysname', @dbName = @db;
    END TRY
    BEGIN CATCH
        -- database unreadable at run time (offline, restoring, insufficient permission); skip it
    END CATCH

    FETCH NEXT FROM db_cursor INTO @db;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

IF OBJECT_ID('tempdb..#Scored') IS NOT NULL DROP TABLE #Scored;
CREATE TABLE #Scored
(
    DatabaseName            sysname NOT NULL,
    ObjectCount             int NOT NULL,
    DocumentedObjects       int NOT NULL,
    TableCount              int NOT NULL,
    DocumentedTables        int NOT NULL,
    ProgrammableCount       int NOT NULL,
    DocumentedProgrammable  int NOT NULL,
    ColumnCount             int NOT NULL,
    DocumentedColumns       int NOT NULL,
    ObjectPct               decimal(5, 1) NULL,
    ColumnPct               decimal(5, 1) NULL,
    ItemScore               int NOT NULL
);

INSERT INTO #Scored
    (DatabaseName, ObjectCount, DocumentedObjects, TableCount, DocumentedTables,
     ProgrammableCount, DocumentedProgrammable, ColumnCount, DocumentedColumns,
     ObjectPct, ColumnPct, ItemScore)
SELECT
    c.DatabaseName,
    c.ObjectCount,
    c.DocumentedObjects,
    c.TableCount,
    c.DocumentedTables,
    c.ProgrammableCount,
    c.DocumentedProgrammable,
    c.ColumnCount,
    c.DocumentedColumns,
    c.ObjectPct,
    c.ColumnPct,
    CASE
        WHEN c.ObjectCount = 0 THEN 3
        WHEN ISNULL(c.ObjectPct, 0.0) >= 90.0 AND ISNULL(c.ColumnPct, 100.0) >= 75.0 THEN 3
        WHEN ISNULL(c.ObjectPct, 0.0) >= 50.0 THEN 2
        WHEN ISNULL(c.ObjectPct, 0.0) > 0.0 THEN 1
        ELSE 0
    END
FROM
(
    SELECT
        d.DatabaseName,
        d.TableCount,
        d.DocumentedTables,
        d.ColumnCount,
        d.DocumentedColumns,
        d.ProgrammableCount,
        d.DocumentedProgrammable,
        d.TableCount + d.ProgrammableCount              AS ObjectCount,
        d.DocumentedTables + d.DocumentedProgrammable   AS DocumentedObjects,
        CAST(100.0 * (d.DocumentedTables + d.DocumentedProgrammable)
             / NULLIF(d.TableCount + d.ProgrammableCount, 0) AS decimal(5, 1)) AS ObjectPct,
        CAST(100.0 * d.DocumentedColumns
             / NULLIF(d.ColumnCount, 0) AS decimal(5, 1))                      AS ColumnPct
    FROM #DocCoverage AS d
) AS c;

IF NOT EXISTS (SELECT 1 FROM #Scored)
BEGIN
    SET @Score = 0;
    SET @Result = N'Fail';
    SET @DatabaseQueried = CAST(ISNULL(DB_NAME(), N'Unknown') AS nvarchar(max));
    SET @Finding = N'No accessible user database could be inspected, so extended-property (MS_Description) documentation coverage on key objects could not be confirmed.';
END
ELSE
BEGIN
    SELECT @Score = MIN(s.ItemScore) FROM #Scored AS s;
    SET @Result = CASE WHEN @Score = 3 THEN N'Pass' ELSE N'Fail' END;

    SET @DatabaseQueried = STUFF(
        (SELECT N', ' + s.DatabaseName
           FROM #Scored AS s
          ORDER BY s.DatabaseName
            FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

    SET @Details = STUFF(
        (SELECT N'; ' + s.DatabaseName + N': '
                + CASE
                    WHEN s.ObjectCount = 0 THEN N'no user objects to document'
                    ELSE CAST(s.DocumentedObjects AS nvarchar(20)) + N'/' + CAST(s.ObjectCount AS nvarchar(20))
                         + N' key objects documented (' + CAST(ISNULL(s.ObjectPct, 0.0) AS nvarchar(10)) + N'%), '
                         + CAST(s.DocumentedTables AS nvarchar(20)) + N'/' + CAST(s.TableCount AS nvarchar(20)) + N' tables, '
                         + CAST(s.DocumentedProgrammable AS nvarchar(20)) + N'/' + CAST(s.ProgrammableCount AS nvarchar(20))
                         + N' views/procedures/functions, '
                         + CAST(s.DocumentedColumns AS nvarchar(20)) + N'/' + CAST(s.ColumnCount AS nvarchar(20))
                         + N' columns (' + CAST(ISNULL(s.ColumnPct, 0.0) AS nvarchar(10)) + N'%)'
                  END
                + N' [score ' + CAST(s.ItemScore AS nvarchar(5)) + N']'
           FROM #Scored AS s
          ORDER BY s.ItemScore ASC, s.DatabaseName ASC
            FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

    SET @Finding =
        CASE
            WHEN @Score = 3 THEN N'All inspected databases meet the expected MS_Description extended-property coverage on key objects (>= 90% of tables/views/procedures/functions and >= 75% of columns), or contain no user objects. '
            WHEN @Score = 2 THEN N'Extended-property documentation on key objects is only partial in at least one database (object coverage below 90% or column coverage below 75%). '
            WHEN @Score = 1 THEN N'Extended-property documentation on key objects is minimal in at least one database (below 50% of key objects carry MS_Description). '
            ELSE N'At least one database has no MS_Description extended properties on any key object. '
        END
        + N'Per-database coverage: ' + ISNULL(@Details, N'none') + N'.';
END

SELECT
    CAST(@Result AS nvarchar(20))            AS Result,
    CAST(@Score AS int)                      AS Score,
    CAST(@DatabaseQueried AS nvarchar(max))  AS DatabaseQueried,
    CAST(@Finding AS nvarchar(max))          AS Finding;

IF OBJECT_ID('tempdb..#DocCoverage') IS NOT NULL DROP TABLE #DocCoverage;
IF OBJECT_ID('tempdb..#Targets') IS NOT NULL DROP TABLE #Targets;
IF OBJECT_ID('tempdb..#Scored') IS NOT NULL DROP TABLE #Scored;