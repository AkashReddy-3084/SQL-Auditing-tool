/* Checklist 8.3.1 - Data dictionary exists for DW/mart tables. Read-only. */
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#DbDict') IS NOT NULL
    DROP TABLE #DbDict;

CREATE TABLE #DbDict
(
    DbName            sysname NOT NULL,
    IsDwCandidate     bit     NOT NULL,
    TableCount        int     NOT NULL,
    TablesWithDesc    int     NOT NULL,
    ColumnCount       int     NOT NULL,
    ColumnsWithDesc   int     NOT NULL,
    DictionaryObjects int     NOT NULL
);

DECLARE @EngineEdition int = CONVERT(int, SERVERPROPERTY('EngineEdition'));
DECLARE @IsAzureSqlDb  bit = CASE WHEN @EngineEdition IN (5, 6, 9, 11) THEN 1 ELSE 0 END;
DECLARE @DbName sysname;
DECLARE @Sql    nvarchar(max);

DECLARE @Collect nvarchar(max) = N'
INSERT INTO #DbDict (DbName, IsDwCandidate, TableCount, TablesWithDesc, ColumnCount, ColumnsWithDesc, DictionaryObjects)
SELECT
    DB_NAME(),
    CASE
        WHEN DB_NAME() LIKE N''%DW%''
          OR DB_NAME() LIKE N''%EDW%''
          OR DB_NAME() LIKE N''%WAREHOUSE%''
          OR DB_NAME() LIKE N''%MART%''
          OR DB_NAME() LIKE N''%ODS%''
          OR EXISTS (SELECT 1 FROM sys.tables t2
                     WHERE t2.is_ms_shipped = 0
                       AND (t2.name LIKE N''Fact%'' OR t2.name LIKE N''Dim%''))
        THEN 1 ELSE 0
    END,
    (SELECT COUNT(*) FROM sys.tables t WHERE t.is_ms_shipped = 0),
    (SELECT COUNT(*) FROM sys.tables t
      WHERE t.is_ms_shipped = 0
        AND EXISTS (SELECT 1 FROM sys.extended_properties ep
                    WHERE ep.class = 1
                      AND ep.major_id = t.object_id
                      AND ep.minor_id = 0
                      AND ep.name IN (N''MS_Description'', N''Description'')
                      AND LEN(CONVERT(nvarchar(max), ep.value)) > 0)),
    (SELECT COUNT(*) FROM sys.columns c
       INNER JOIN sys.tables t ON t.object_id = c.object_id
      WHERE t.is_ms_shipped = 0),
    (SELECT COUNT(*) FROM sys.columns c
       INNER JOIN sys.tables t ON t.object_id = c.object_id
      WHERE t.is_ms_shipped = 0
        AND EXISTS (SELECT 1 FROM sys.extended_properties ep
                    WHERE ep.class = 1
                      AND ep.major_id = c.object_id
                      AND ep.minor_id = c.column_id
                      AND ep.name IN (N''MS_Description'', N''Description'')
                      AND LEN(CONVERT(nvarchar(max), ep.value)) > 0)),
    (SELECT COUNT(*) FROM sys.objects o
      WHERE o.type IN (''U'', ''V'')
        AND o.is_ms_shipped = 0
        AND (REPLACE(o.name, N''_'', N'''') LIKE N''%DATADICTIONARY%''
          OR REPLACE(o.name, N''_'', N'''') LIKE N''%DATACATALOG%''
          OR REPLACE(o.name, N''_'', N'''') LIKE N''%COLUMNDICTIONARY%''));
';

IF @IsAzureSqlDb = 1
BEGIN
    /* Azure SQL Database / Synapse: cross-database access is not available, inspect the connected database only. */
    EXEC sys.sp_executesql @Collect;
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.source_database_id IS NULL
          AND d.name NOT IN (N'distribution', N'SSISDB', N'ReportServer', N'ReportServerTempDB')
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';' + @Collect;
            EXEC sys.sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            /* Database became inaccessible mid-run; skip it rather than aborting the audit. */
            SET @Sql = NULL;
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

DECLARE @DwDbCount   int,
        @TotalTables int,
        @DescTables  int,
        @TotalCols   int,
        @DescCols    int,
        @DwWithDict  int;

SELECT
    @DwDbCount   = COUNT(*),
    @TotalTables = ISNULL(SUM(d.TableCount), 0),
    @DescTables  = ISNULL(SUM(d.TablesWithDesc), 0),
    @TotalCols   = ISNULL(SUM(d.ColumnCount), 0),
    @DescCols    = ISNULL(SUM(d.ColumnsWithDesc), 0),
    @DwWithDict  = ISNULL(SUM(CASE WHEN d.DictionaryObjects > 0 THEN 1 ELSE 0 END), 0)
FROM #DbDict AS d
WHERE d.IsDwCandidate = 1
  AND d.TableCount > 0;

DECLARE @DatabaseQueried nvarchar(max);

SELECT @DatabaseQueried = STUFF((SELECT N', ' + d.DbName
                                 FROM #DbDict AS d
                                 WHERE d.IsDwCandidate = 1
                                   AND d.TableCount > 0
                                 ORDER BY d.DbName
                                 FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'');

DECLARE @TablePct decimal(5,1) = CASE WHEN @TotalTables > 0
                                      THEN CONVERT(decimal(5,1), 100.0 * @DescTables / @TotalTables)
                                      ELSE CONVERT(decimal(5,1), 0) END;
DECLARE @ColPct   decimal(5,1) = CASE WHEN @TotalCols > 0
                                      THEN CONVERT(decimal(5,1), 100.0 * @DescCols / @TotalCols)
                                      ELSE CONVERT(decimal(5,1), 0) END;

DECLARE @Result  nvarchar(20),
        @Score   int,
        @Finding nvarchar(max);

IF @DwDbCount = 0 OR @DatabaseQueried IS NULL
BEGIN
    SET @Score           = 0;
    SET @DatabaseQueried = N'None';
    SET @Finding         = N'No database found to be queried';
END
ELSE IF (@TablePct >= 90.0 AND @ColPct >= 80.0) OR @DwWithDict = @DwDbCount
BEGIN
    SET @Score   = 3;
    SET @Finding = N'Data dictionary metadata is present for the ' + CONVERT(nvarchar(10), @DwDbCount)
                 + N' DW/mart database(s) examined: ' + CONVERT(nvarchar(10), @DescTables) + N' of '
                 + CONVERT(nvarchar(10), @TotalTables) + N' tables (' + CONVERT(nvarchar(10), @TablePct)
                 + N'%) and ' + CONVERT(nvarchar(10), @DescCols) + N' of ' + CONVERT(nvarchar(10), @TotalCols)
                 + N' columns (' + CONVERT(nvarchar(10), @ColPct) + N'%) carry MS_Description extended properties; '
                 + CONVERT(nvarchar(10), @DwWithDict) + N' database(s) also contain a dedicated data dictionary/catalog object.';
END
ELSE IF @TablePct >= 50.0 OR @DwWithDict > 0
BEGIN
    SET @Score   = 2;
    SET @Finding = N'Data dictionary coverage is partial across the ' + CONVERT(nvarchar(10), @DwDbCount)
                 + N' DW/mart database(s) examined: ' + CONVERT(nvarchar(10), @DescTables) + N' of '
                 + CONVERT(nvarchar(10), @TotalTables) + N' tables (' + CONVERT(nvarchar(10), @TablePct)
                 + N'%) and ' + CONVERT(nvarchar(10), @DescCols) + N' of ' + CONVERT(nvarchar(10), @TotalCols)
                 + N' columns (' + CONVERT(nvarchar(10), @ColPct) + N'%) are documented; '
                 + CONVERT(nvarchar(10), @DwWithDict) + N' of ' + CONVERT(nvarchar(10), @DwDbCount)
                 + N' database(s) contain a dedicated data dictionary/catalog object.';
END
ELSE IF @DescTables > 0 OR @DescCols > 0
BEGIN
    SET @Score   = 1;
    SET @Finding = N'Data dictionary coverage is minimal across the ' + CONVERT(nvarchar(10), @DwDbCount)
                 + N' DW/mart database(s) examined: only ' + CONVERT(nvarchar(10), @DescTables) + N' of '
                 + CONVERT(nvarchar(10), @TotalTables) + N' tables (' + CONVERT(nvarchar(10), @TablePct)
                 + N'%) and ' + CONVERT(nvarchar(10), @DescCols) + N' of ' + CONVERT(nvarchar(10), @TotalCols)
                 + N' columns (' + CONVERT(nvarchar(10), @ColPct)
                 + N'%) are documented, and no dedicated data dictionary/catalog object was found.';
END
ELSE
BEGIN
    SET @Score   = 0;
    SET @Finding = N'No data dictionary evidence was found in the ' + CONVERT(nvarchar(10), @DwDbCount)
                 + N' DW/mart database(s) examined: none of the ' + CONVERT(nvarchar(10), @TotalTables)
                 + N' tables and none of the ' + CONVERT(nvarchar(10), @TotalCols)
                 + N' columns carry MS_Description extended properties, and no dedicated data dictionary/catalog table or view exists.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;