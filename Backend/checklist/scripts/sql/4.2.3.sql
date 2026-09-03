SET NOCOUNT ON;

DECLARE @Result NVARCHAR(20) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(4000) = N'None';
DECLARE @Finding NVARCHAR(4000) = N'No database found to be queried';
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF OBJECT_ID('tempdb..#FactColumns') IS NOT NULL
    DROP TABLE #FactColumns;

CREATE TABLE #FactColumns
(
    DatabaseName SYSNAME NOT NULL,
    SchemaName   SYSNAME NOT NULL,
    TableName    SYSNAME NOT NULL,
    ColumnName   SYSNAME NOT NULL,
    ColumnKind   NVARCHAR(20) NOT NULL
);

DECLARE @Collect NVARCHAR(MAX) = N'
SELECT
    DB_NAME() AS DatabaseName,
    s.name    AS SchemaName,
    t.name    AS TableName,
    c.name    AS ColumnName,
    CASE
        WHEN EXISTS (SELECT 1 FROM sys.foreign_key_columns AS fkc
                     WHERE fkc.parent_object_id = c.object_id
                       AND fkc.parent_column_id = c.column_id) THEN N''ForeignKey''
        WHEN EXISTS (SELECT 1 FROM sys.index_columns AS ic
                     INNER JOIN sys.indexes AS i
                         ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                     WHERE ic.object_id = c.object_id
                       AND ic.column_id = c.column_id
                       AND (i.is_primary_key = 1 OR i.is_unique_constraint = 1)) THEN N''KeyColumn''
        WHEN c.is_identity = 1 OR c.is_rowguidcol = 1 THEN N''KeyColumn''
        WHEN ty.name IN (N''char'', N''varchar'', N''nchar'', N''nvarchar'', N''text'', N''ntext'', N''xml'') THEN N''Descriptive''
        ELSE N''Measure''
    END AS ColumnKind
FROM sys.tables AS t
INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
INNER JOIN sys.columns AS c ON c.object_id = t.object_id
INNER JOIN sys.types AS ty ON ty.user_type_id = c.user_type_id
WHERE t.is_ms_shipped = 0
  AND (t.name LIKE N''Fact%''
       OR t.name LIKE N''%[_]Fact''
       OR t.name LIKE N''%[_]Facts''
       OR t.name LIKE N''F[_]%''
       OR s.name LIKE N''Fact%'');';

BEGIN TRY
    IF @EngineEdition IN (5, 6, 11)
    BEGIN
        INSERT INTO #FactColumns (DatabaseName, SchemaName, TableName, ColumnName, ColumnKind)
        EXEC sp_executesql @Collect;
    END
    ELSE
    BEGIN
        DECLARE @DbName SYSNAME;
        DECLARE @Sql NVARCHAR(MAX);

        DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT d.name
            FROM sys.databases AS d
            WHERE d.database_id > 4
              AND d.state = 0
              AND d.source_database_id IS NULL
              AND d.is_distributor = 0
              AND d.name NOT IN (N'ReportServer', N'ReportServerTempDB', N'SSISDB', N'distribution')
              AND HAS_DBACCESS(d.name) = 1
              AND DATABASEPROPERTYEX(d.name, 'Updateability') IS NOT NULL
            ORDER BY d.name;

        OPEN db_cursor;
        FETCH NEXT FROM db_cursor INTO @DbName;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N'; ' + @Collect;

            BEGIN TRY
                INSERT INTO #FactColumns (DatabaseName, SchemaName, TableName, ColumnName, ColumnKind)
                EXEC sp_executesql @Sql;
            END TRY
            BEGIN CATCH
                /* database not readable by the audit login - skip it */
            END CATCH;

            FETCH NEXT FROM db_cursor INTO @DbName;
        END

        CLOSE db_cursor;
        DEALLOCATE db_cursor;
    END
END TRY
BEGIN CATCH
    SET @Finding = N'Metadata collection failed: ' + ERROR_MESSAGE();
END CATCH;

DECLARE @DbCount INT = 0;
DECLARE @FactTableCount INT = 0;
DECLARE @OffendingTableCount INT = 0;
DECLARE @DescriptiveColumnCount INT = 0;
DECLARE @Examples NVARCHAR(2000) = NULL;

SELECT @DbCount = COUNT(DISTINCT DatabaseName)
FROM #FactColumns;

SELECT @FactTableCount = COUNT(*)
FROM (SELECT DISTINCT DatabaseName, SchemaName, TableName FROM #FactColumns) AS ft;

SELECT @OffendingTableCount = COUNT(*)
FROM (SELECT DISTINCT DatabaseName, SchemaName, TableName
      FROM #FactColumns
      WHERE ColumnKind = N'Descriptive') AS bt;

SELECT @DescriptiveColumnCount = COUNT(*)
FROM #FactColumns
WHERE ColumnKind = N'Descriptive';

IF @FactTableCount = 0
BEGIN
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
    SET @Score = 0;
END
ELSE
BEGIN
    SELECT @DatabaseQueried = STUFF(
        (SELECT N', ' + d.DatabaseName
         FROM (SELECT DISTINCT DatabaseName FROM #FactColumns) AS d
         ORDER BY d.DatabaseName
         FOR XML PATH(N''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

    IF @DescriptiveColumnCount > 0
    BEGIN
        SELECT @Examples = STUFF(
            (SELECT N'; ' + x.DatabaseName + N'.' + x.SchemaName + N'.' + x.TableName + N'.' + x.ColumnName
             FROM (SELECT TOP (5) DatabaseName, SchemaName, TableName, ColumnName
                   FROM #FactColumns
                   WHERE ColumnKind = N'Descriptive'
                   ORDER BY DatabaseName, SchemaName, TableName, ColumnName) AS x
             ORDER BY x.DatabaseName, x.SchemaName, x.TableName, x.ColumnName
             FOR XML PATH(N''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');
    END

    IF @DescriptiveColumnCount = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = N'All ' + CAST(@FactTableCount AS NVARCHAR(20))
            + N' fact table(s) across ' + CAST(@DbCount AS NVARCHAR(20))
            + N' database(s) expose only key, foreign-key and non-textual measure columns; no descriptive (char/varchar/nchar/nvarchar/text/ntext/xml) attributes were found outside the key set.';
    END
    ELSE IF (@OffendingTableCount * 100) <= (@FactTableCount * 25)
    BEGIN
        SET @Score = 2;
        SET @Finding = CAST(@OffendingTableCount AS NVARCHAR(20)) + N' of '
            + CAST(@FactTableCount AS NVARCHAR(20)) + N' fact table(s) across '
            + CAST(@DbCount AS NVARCHAR(20)) + N' database(s) carry '
            + CAST(@DescriptiveColumnCount AS NVARCHAR(20))
            + N' descriptive (text/XML) column(s) that are neither foreign keys nor keys. Examples: '
            + ISNULL(@Examples, N'n/a') + N'.';
    END
    ELSE IF (@OffendingTableCount * 100) <= (@FactTableCount * 50)
    BEGIN
        SET @Score = 1;
        SET @Finding = CAST(@OffendingTableCount AS NVARCHAR(20)) + N' of '
            + CAST(@FactTableCount AS NVARCHAR(20)) + N' fact table(s) across '
            + CAST(@DbCount AS NVARCHAR(20)) + N' database(s) carry '
            + CAST(@DescriptiveColumnCount AS NVARCHAR(20))
            + N' descriptive (text/XML) column(s) that belong in dimensions. Examples: '
            + ISNULL(@Examples, N'n/a') + N'.';
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = CAST(@OffendingTableCount AS NVARCHAR(20)) + N' of '
            + CAST(@FactTableCount AS NVARCHAR(20)) + N' fact table(s) across '
            + CAST(@DbCount AS NVARCHAR(20)) + N' database(s) carry '
            + CAST(@DescriptiveColumnCount AS NVARCHAR(20))
            + N' descriptive (text/XML) column(s) instead of restricting the grain to foreign keys and measures. Examples: '
            + ISNULL(@Examples, N'n/a') + N'.';
    END
END

SET @Result = CASE
                  WHEN @Score = 3 THEN N'Pass'
                  WHEN @Score = 0 THEN N'Fail'
                  ELSE N'Partial'
              END;

IF OBJECT_ID('tempdb..#FactColumns') IS NOT NULL
    DROP TABLE #FactColumns;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;