/* Checklist 5.4.6 - Identifiers / Keys: uniqueness verified; format consistent; no nulls in keys */
/* READ-ONLY: only catalog views are read; writes are limited to session temp tables. */
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#Dbs') IS NOT NULL DROP TABLE #Dbs;
IF OBJECT_ID('tempdb..#TableKeys') IS NOT NULL DROP TABLE #TableKeys;
IF OBJECT_ID('tempdb..#IdCols') IS NOT NULL DROP TABLE #IdCols;

CREATE TABLE #Dbs (DatabaseName SYSNAME);

CREATE TABLE #TableKeys (
    DatabaseName    SYSNAME,
    SchemaName      SYSNAME,
    TableName       SYSNAME,
    HasPK           INT,
    HasUniqueIndex  INT,
    NullableKeyCols INT
);

CREATE TABLE #IdCols (
    DatabaseName  SYSNAME,
    SchemaName    SYSNAME,
    TableName     SYSNAME,
    ColumnName    SYSNAME,
    DataTypeDesc  NVARCHAR(200),
    IsNullable    INT,
    IsInUniqueKey INT
);

DECLARE @EngineEdition INT = ISNULL(CAST(SERVERPROPERTY('EngineEdition') AS INT), 0);

IF @EngineEdition = 5
BEGIN
    /* Azure SQL Database: cross-database queries are not supported, inspect the current database only. */
    INSERT INTO #Dbs (DatabaseName) VALUES (DB_NAME());
END
ELSE
BEGIN
    INSERT INTO #Dbs (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.source_database_id IS NULL
      AND d.state = 0
      AND d.is_read_only = 0
      AND d.name NOT IN ('distribution', 'SSISDB', 'ReportServer', 'ReportServerTempDB')
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @db SYSNAME, @qdb NVARCHAR(300), @sql NVARCHAR(MAX);
DECLARE @SkippedDbs INT = 0;

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Dbs ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @qdb = QUOTENAME(@db);

    BEGIN TRY
        SET @sql = N'
SELECT
    @DbNameParam,
    s.name,
    t.name,
    CASE WHEN EXISTS (SELECT 1 FROM ' + @qdb + N'.sys.indexes AS i
                      WHERE i.object_id = t.object_id AND i.is_primary_key = 1) THEN 1 ELSE 0 END,
    CASE WHEN EXISTS (SELECT 1 FROM ' + @qdb + N'.sys.indexes AS i
                      WHERE i.object_id = t.object_id AND i.is_unique = 1
                        AND i.is_primary_key = 0 AND i.has_filter = 0) THEN 1 ELSE 0 END,
    ISNULL((SELECT COUNT(*)
              FROM ' + @qdb + N'.sys.indexes AS i
              INNER JOIN ' + @qdb + N'.sys.index_columns AS ic
                      ON ic.object_id = i.object_id AND ic.index_id = i.index_id
              INNER JOIN ' + @qdb + N'.sys.columns AS c
                      ON c.object_id = ic.object_id AND c.column_id = ic.column_id
             WHERE i.object_id = t.object_id
               AND i.is_unique = 1
               AND ic.is_included_column = 0
               AND c.is_nullable = 1), 0)
FROM ' + @qdb + N'.sys.tables AS t
INNER JOIN ' + @qdb + N'.sys.schemas AS s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
  AND t.type = ''U''
  AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'');';

        INSERT INTO #TableKeys (DatabaseName, SchemaName, TableName, HasPK, HasUniqueIndex, NullableKeyCols)
        EXEC sp_executesql @sql, N'@DbNameParam SYSNAME', @DbNameParam = @db;

        SET @sql = N'
SELECT
    @DbNameParam,
    s.name,
    t.name,
    c.name,
    ty.name
        + CASE
            WHEN ty.name IN (''varchar'', ''char'', ''varbinary'', ''binary'')
                THEN ''('' + CASE WHEN c.max_length = -1 THEN ''max'' ELSE CAST(c.max_length AS NVARCHAR(10)) END + '')''
            WHEN ty.name IN (''nvarchar'', ''nchar'')
                THEN ''('' + CASE WHEN c.max_length = -1 THEN ''max'' ELSE CAST(c.max_length / 2 AS NVARCHAR(10)) END + '')''
            WHEN ty.name IN (''decimal'', ''numeric'')
                THEN ''('' + CAST(c.precision AS NVARCHAR(10)) + '','' + CAST(c.scale AS NVARCHAR(10)) + '')''
            ELSE ''''
          END,
    CAST(c.is_nullable AS INT),
    CASE WHEN EXISTS (SELECT 1
                        FROM ' + @qdb + N'.sys.index_columns AS ic
                        INNER JOIN ' + @qdb + N'.sys.indexes AS i
                                ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                       WHERE ic.object_id = c.object_id
                         AND ic.column_id = c.column_id
                         AND ic.is_included_column = 0
                         AND i.is_unique = 1) THEN 1 ELSE 0 END
FROM ' + @qdb + N'.sys.columns AS c
INNER JOIN ' + @qdb + N'.sys.tables AS t ON t.object_id = c.object_id
INNER JOIN ' + @qdb + N'.sys.schemas AS s ON s.schema_id = t.schema_id
INNER JOIN ' + @qdb + N'.sys.types AS ty ON ty.user_type_id = c.user_type_id
WHERE t.is_ms_shipped = 0
  AND t.type = ''U''
  AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'')
  AND (c.name LIKE ''%id''
       OR c.name LIKE ''%key''
       OR c.name LIKE ''%code''
       OR c.name LIKE ''%number''
       OR c.name LIKE ''%guid'');';

        INSERT INTO #IdCols (DatabaseName, SchemaName, TableName, ColumnName, DataTypeDesc, IsNullable, IsInUniqueKey)
        EXEC sp_executesql @sql, N'@DbNameParam SYSNAME', @DbNameParam = @db;
    END TRY
    BEGIN CATCH
        SET @SkippedDbs = @SkippedDbs + 1;
    END CATCH

    FETCH NEXT FROM db_cur INTO @db;
END

CLOSE db_cur;
DEALLOCATE db_cur;

DECLARE @DbCount            INT = ISNULL((SELECT COUNT(*) FROM #Dbs), 0);
DECLARE @ScannedDbs         INT = ISNULL((SELECT COUNT(DISTINCT DatabaseName) FROM #TableKeys), 0);
DECLARE @TotalTables        INT = ISNULL((SELECT COUNT(*) FROM #TableKeys), 0);
DECLARE @NoUniqueness       INT = ISNULL((SELECT COUNT(*) FROM #TableKeys WHERE HasPK = 0 AND HasUniqueIndex = 0), 0);
DECLARE @NoPK               INT = ISNULL((SELECT COUNT(*) FROM #TableKeys WHERE HasPK = 0), 0);
DECLARE @NullableKeyTables  INT = ISNULL((SELECT COUNT(*) FROM #TableKeys WHERE NullableKeyCols > 0), 0);
DECLARE @IdColCount         INT = ISNULL((SELECT COUNT(*) FROM #IdCols), 0);
DECLARE @NullableIdCols     INT = ISNULL((SELECT COUNT(*) FROM #IdCols WHERE IsNullable = 1 AND IsInUniqueKey = 0), 0);
DECLARE @InconsistentNames  INT = ISNULL((SELECT COUNT(*) FROM (
                                              SELECT DatabaseName, ColumnName
                                              FROM #IdCols
                                              GROUP BY DatabaseName, ColumnName
                                              HAVING COUNT(DISTINCT DataTypeDesc) > 1) AS x), 0);

DECLARE @Coverage DECIMAL(5, 2) =
    ISNULL(CASE WHEN @TotalTables = 0 THEN CAST(100.00 AS DECIMAL(5, 2))
                ELSE CAST((@TotalTables - @NoUniqueness) * 100.0 / @TotalTables AS DECIMAL(5, 2)) END,
           CAST(0.00 AS DECIMAL(5, 2)));

DECLARE @DatabaseQueried NVARCHAR(MAX);
SET @DatabaseQueried = ISNULL(STUFF(ISNULL((SELECT N', ' + d.DatabaseName
                                            FROM #Dbs AS d
                                            ORDER BY d.DatabaseName
                                            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), N'  None'), 1, 2, N''), N'None');
IF LEN(@DatabaseQueried) = 0 SET @DatabaseQueried = N'None';

DECLARE @SampleNoKey NVARCHAR(MAX);
SET @SampleNoKey = ISNULL(STUFF(ISNULL((SELECT TOP (5) N'; ' + k.DatabaseName + N'.' + k.SchemaName + N'.' + k.TableName
                                        FROM #TableKeys AS k
                                        WHERE k.HasPK = 0 AND k.HasUniqueIndex = 0
                                        ORDER BY k.DatabaseName, k.SchemaName, k.TableName
                                        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), N'  none'), 1, 2, N''), N'none');

DECLARE @SampleNullableKey NVARCHAR(MAX);
SET @SampleNullableKey = ISNULL(STUFF(ISNULL((SELECT TOP (5) N'; ' + k.DatabaseName + N'.' + k.SchemaName + N'.' + k.TableName
                                              FROM #TableKeys AS k
                                              WHERE k.NullableKeyCols > 0
                                              ORDER BY k.DatabaseName, k.SchemaName, k.TableName
                                              FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), N'  none'), 1, 2, N''), N'none');

DECLARE @SampleInconsistent NVARCHAR(MAX);
SET @SampleInconsistent = ISNULL(STUFF(ISNULL((SELECT TOP (5) N'; ' + g.DatabaseName + N'.' + g.ColumnName
                                               FROM (SELECT DatabaseName, ColumnName
                                                     FROM #IdCols
                                                     GROUP BY DatabaseName, ColumnName
                                                     HAVING COUNT(DISTINCT DataTypeDesc) > 1) AS g
                                               ORDER BY g.DatabaseName, g.ColumnName
                                               FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), N'  none'), 1, 2, N''), N'none');

DECLARE @Score INT;

IF @DbCount = 0 OR @ScannedDbs = 0
    SET @Score = 1;
ELSE IF @TotalTables = 0
    SET @Score = 3;
ELSE IF @NoUniqueness = 0 AND @NullableKeyTables = 0 AND @InconsistentNames = 0
    SET @Score = 3;
ELSE IF @Coverage >= 90.00 AND @NullableKeyTables = 0
    SET @Score = 2;
ELSE
    SET @Score = 1;

SET @Score = ISNULL(@Score, 1);

DECLARE @Result NVARCHAR(10);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DECLARE @Finding NVARCHAR(MAX);

IF @DbCount = 0 OR @ScannedDbs = 0
    SET @Finding = N'No user database could be inspected (databases discovered: ' + CAST(@DbCount AS NVARCHAR(10))
                 + N', inaccessible/skipped: ' + CAST(@SkippedDbs AS NVARCHAR(10))
                 + N'). Identifier and key integrity could not be verified.';
ELSE IF @TotalTables = 0
    SET @Finding = N'Databases inspected: ' + CAST(@ScannedDbs AS NVARCHAR(10))
                 + N'. No user tables were found, so there are no identifier or key columns to validate.';
ELSE
    SET @Finding = N'Databases inspected: ' + CAST(@ScannedDbs AS NVARCHAR(10))
                 + N' of ' + CAST(@DbCount AS NVARCHAR(10))
                 + N' (skipped: ' + CAST(@SkippedDbs AS NVARCHAR(10)) + N'). '
                 + N'User tables: ' + CAST(@TotalTables AS NVARCHAR(10)) + N'. '
                 + N'Uniqueness enforced on ' + CAST(@TotalTables - @NoUniqueness AS NVARCHAR(10))
                 + N' table(s) (' + CAST(@Coverage AS NVARCHAR(10)) + N'%); '
                 + CAST(@NoUniqueness AS NVARCHAR(10)) + N' table(s) have no primary key or unique constraint [e.g. '
                 + @SampleNoKey + N']. '
                 + N'Tables without a primary key: ' + CAST(@NoPK AS NVARCHAR(10)) + N'. '
                 + N'Tables whose unique key contains nullable column(s): ' + CAST(@NullableKeyTables AS NVARCHAR(10))
                 + N' [e.g. ' + @SampleNullableKey + N']. '
                 + N'Identifier-named columns examined: ' + CAST(@IdColCount AS NVARCHAR(10))
                 + N', of which ' + CAST(@NullableIdCols AS NVARCHAR(10)) + N' are nullable and not covered by a unique key. '
                 + N'Identifier names declared with conflicting data types within a database: '
                 + CAST(@InconsistentNames AS NVARCHAR(10)) + N' [e.g. ' + @SampleInconsistent + N'].';

SET @Finding = ISNULL(@Finding, N'Identifier and key integrity could not be determined.');

SELECT
    ISNULL(@Result, N'Fail')                                              AS Result,
    ISNULL(@Score, 1)                                                     AS Score,
    ISNULL(@DatabaseQueried, N'None')                                     AS DatabaseQueried,
    ISNULL(@Finding, N'Identifier and key integrity could not be determined.') AS Finding;