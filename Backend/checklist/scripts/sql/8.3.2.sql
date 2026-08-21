SET NOCOUNT ON;

/* Checklist 8.3.2 - Technical metadata (schema) captured and current
   Read-only. Inspects sys.extended_properties (MS_Description) coverage over
   user tables and columns, plus recent schema changes that remain undocumented. */

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF OBJECT_ID('tempdb..#MetadataCoverage') IS NOT NULL
    DROP TABLE #MetadataCoverage;

CREATE TABLE #MetadataCoverage
(
    DatabaseName       SYSNAME       NOT NULL,
    TotalTables        INT           NOT NULL,
    DocumentedTables   INT           NOT NULL,
    TotalColumns       INT           NOT NULL,
    DocumentedColumns  INT           NOT NULL,
    RecentUndocumented INT           NOT NULL
);

DECLARE @InnerSql NVARCHAR(MAX) = N'
SELECT
    DB_NAME() AS DatabaseName,
    (SELECT COUNT(*)
       FROM sys.tables AS t
      WHERE t.is_ms_shipped = 0) AS TotalTables,
    (SELECT COUNT(*)
       FROM sys.tables AS t
      WHERE t.is_ms_shipped = 0
        AND EXISTS (SELECT 1
                      FROM sys.extended_properties AS ep
                     WHERE ep.class = 1
                       AND ep.major_id = t.object_id
                       AND ep.minor_id = 0
                       AND ep.name = ''MS_Description''
                       AND LTRIM(RTRIM(CONVERT(NVARCHAR(MAX), ep.value))) <> '''')) AS DocumentedTables,
    (SELECT COUNT(*)
       FROM sys.columns AS c
       INNER JOIN sys.tables AS t ON t.object_id = c.object_id
      WHERE t.is_ms_shipped = 0) AS TotalColumns,
    (SELECT COUNT(*)
       FROM sys.columns AS c
       INNER JOIN sys.tables AS t ON t.object_id = c.object_id
      WHERE t.is_ms_shipped = 0
        AND EXISTS (SELECT 1
                      FROM sys.extended_properties AS ep
                     WHERE ep.class = 1
                       AND ep.major_id = c.object_id
                       AND ep.minor_id = c.column_id
                       AND ep.name = ''MS_Description''
                       AND LTRIM(RTRIM(CONVERT(NVARCHAR(MAX), ep.value))) <> '''')) AS DocumentedColumns,
    (SELECT COUNT(*)
       FROM sys.tables AS t
      WHERE t.is_ms_shipped = 0
        AND t.modify_date >= DATEADD(DAY, -90, GETDATE())
        AND NOT EXISTS (SELECT 1
                          FROM sys.extended_properties AS ep
                         WHERE ep.class = 1
                           AND ep.major_id = t.object_id
                           AND ep.minor_id = 0
                           AND ep.name = ''MS_Description''
                           AND LTRIM(RTRIM(CONVERT(NVARCHAR(MAX), ep.value))) <> '''')) AS RecentUndocumented;';

IF @EngineEdition = 5
BEGIN
    /* Azure SQL Database: cross-database access is not available, inspect current database only. */
    BEGIN TRY
        INSERT INTO #MetadataCoverage
            (DatabaseName, TotalTables, DocumentedTables, TotalColumns, DocumentedColumns, RecentUndocumented)
        EXEC sp_executesql @InnerSql;
    END TRY
    BEGIN CATCH
        /* Database not inspectable - leave it out of the sample. */
    END CATCH
END
ELSE
BEGIN
    DECLARE @DbName SYSNAME;
    DECLARE @Sql NVARCHAR(MAX);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
          FROM sys.databases AS d
         WHERE d.database_id > 4
           AND d.name NOT IN ('master', 'model', 'msdb', 'tempdb')
           AND d.state = 0
           AND d.is_in_standby = 0
           AND d.source_database_id IS NULL
           AND HAS_DBACCESS(d.name) = 1
         ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';' + @InnerSql;

            INSERT INTO #MetadataCoverage
                (DatabaseName, TotalTables, DocumentedTables, TotalColumns, DocumentedColumns, RecentUndocumented)
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            /* Inaccessible or non-readable database - skip it. */
        END CATCH

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

DECLARE @DbCount            INT = 0,
        @TotalTables        INT = 0,
        @DocumentedTables   INT = 0,
        @TotalColumns       INT = 0,
        @DocumentedColumns  INT = 0,
        @RecentUndocumented INT = 0;

SELECT @DbCount            = COUNT(*),
       @TotalTables        = ISNULL(SUM(TotalTables), 0),
       @DocumentedTables   = ISNULL(SUM(DocumentedTables), 0),
       @TotalColumns       = ISNULL(SUM(TotalColumns), 0),
       @DocumentedColumns  = ISNULL(SUM(DocumentedColumns), 0),
       @RecentUndocumented = ISNULL(SUM(RecentUndocumented), 0)
  FROM #MetadataCoverage;

DECLARE @TableCoverage  DECIMAL(9, 2) = CASE WHEN @TotalTables  = 0 THEN 0
                                             ELSE (@DocumentedTables  * 100.0) / @TotalTables END;
DECLARE @ColumnCoverage DECIMAL(9, 2) = CASE WHEN @TotalColumns = 0 THEN 0
                                             ELSE (@DocumentedColumns * 100.0) / @TotalColumns END;

DECLARE @DbList NVARCHAR(MAX) =
    STUFF((SELECT N', ' + mc.DatabaseName
             FROM #MetadataCoverage AS mc
            ORDER BY mc.DatabaseName
              FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @WorstDbs NVARCHAR(MAX) =
    STUFF((SELECT TOP (5) N', ' + mc.DatabaseName + N' ('
                  + CAST(mc.DocumentedTables AS NVARCHAR(20)) + N'/'
                  + CAST(mc.TotalTables AS NVARCHAR(20)) + N' tables described)'
             FROM #MetadataCoverage AS mc
            WHERE mc.TotalTables > mc.DocumentedTables
            ORDER BY (mc.TotalTables - mc.DocumentedTables) DESC, mc.DatabaseName
              FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @Score   INT;
DECLARE @Finding NVARCHAR(MAX);

IF @DbCount = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No accessible user database could be inspected on this instance, so technical metadata coverage could not be measured.';
END
ELSE IF @TotalTables = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'No user tables exist in the ' + CAST(@DbCount AS NVARCHAR(20))
                 + N' inspected user database(s), so there is no technical schema metadata to capture.';
END
ELSE IF @DocumentedTables = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No technical metadata is captured: 0 of ' + CAST(@TotalTables AS NVARCHAR(20))
                 + N' user tables and 0 of ' + CAST(@TotalColumns AS NVARCHAR(20))
                 + N' columns across ' + CAST(@DbCount AS NVARCHAR(20))
                 + N' database(s) carry an MS_Description extended property.';
END
ELSE IF @TableCoverage >= 90.0 AND @ColumnCoverage >= 75.0 AND @RecentUndocumented = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'Technical metadata is captured and current: ' + CAST(@DocumentedTables AS NVARCHAR(20))
                 + N' of ' + CAST(@TotalTables AS NVARCHAR(20)) + N' tables ('
                 + CAST(@TableCoverage AS NVARCHAR(20)) + N'%) and '
                 + CAST(@DocumentedColumns AS NVARCHAR(20)) + N' of ' + CAST(@TotalColumns AS NVARCHAR(20))
                 + N' columns (' + CAST(@ColumnCoverage AS NVARCHAR(20))
                 + N'%) are described across ' + CAST(@DbCount AS NVARCHAR(20))
                 + N' database(s), and every table modified in the last 90 days has a description.';
END
ELSE IF @TableCoverage >= 90.0 AND @RecentUndocumented > 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'Technical metadata is broadly captured (' + CAST(@TableCoverage AS NVARCHAR(20))
                 + N'% of ' + CAST(@TotalTables AS NVARCHAR(20)) + N' tables, '
                 + CAST(@ColumnCoverage AS NVARCHAR(20)) + N'% of ' + CAST(@TotalColumns AS NVARCHAR(20))
                 + N' columns) but is not fully current: ' + CAST(@RecentUndocumented AS NVARCHAR(20))
                 + N' table(s) modified in the last 90 days have no description.';
END
ELSE IF @TableCoverage >= 50.0
BEGIN
    SET @Score = 2;
    SET @Finding = N'Technical metadata is partially captured: ' + CAST(@DocumentedTables AS NVARCHAR(20))
                 + N' of ' + CAST(@TotalTables AS NVARCHAR(20)) + N' tables ('
                 + CAST(@TableCoverage AS NVARCHAR(20)) + N'%) and '
                 + CAST(@ColumnCoverage AS NVARCHAR(20)) + N'% of columns are described; '
                 + CAST(@RecentUndocumented AS NVARCHAR(20))
                 + N' recently modified table(s) are undocumented. Largest gaps: '
                 + ISNULL(@WorstDbs, N'none') + N'.';
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = N'Technical metadata capture is minimal: only ' + CAST(@DocumentedTables AS NVARCHAR(20))
                 + N' of ' + CAST(@TotalTables AS NVARCHAR(20)) + N' tables ('
                 + CAST(@TableCoverage AS NVARCHAR(20)) + N'%) and '
                 + CAST(@ColumnCoverage AS NVARCHAR(20)) + N'% of columns are described; '
                 + CAST(@RecentUndocumented AS NVARCHAR(20))
                 + N' recently modified table(s) are undocumented. Largest gaps: '
                 + ISNULL(@WorstDbs, N'none') + N'.';
END

DECLARE @Result NVARCHAR(10);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score  AS Score,
    ISNULL(@DbList, N'None') AS DatabaseQueried,
    @Finding AS Finding;

IF OBJECT_ID('tempdb..#MetadataCoverage') IS NOT NULL
    DROP TABLE #MetadataCoverage;