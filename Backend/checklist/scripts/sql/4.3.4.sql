/*
    Checklist item : 4.3.4 - No redundant/duplicate/overlapping indexes
    Scope          : DATABASE (all accessible user databases; current database only on Azure SQL Database)
    Type           : Read-only. Only temporary tables are written.
    Output         : Result, Score, DatabaseQueried, Finding
*/
SET NOCOUNT ON;

DECLARE @IsAzureSqlDb bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#IndexColumns') IS NOT NULL DROP TABLE #IndexColumns;
IF OBJECT_ID('tempdb..#IndexDef') IS NOT NULL DROP TABLE #IndexDef;
IF OBJECT_ID('tempdb..#Redundant') IS NOT NULL DROP TABLE #Redundant;

CREATE TABLE #IndexColumns
(
    DatabaseName sysname  NOT NULL,
    SchemaName   sysname  NOT NULL,
    TableName    sysname  NOT NULL,
    IndexName    sysname  NOT NULL,
    ObjectId     int      NOT NULL,
    IndexId      int      NOT NULL,
    IsUnique     bit      NOT NULL,
    IsPrimaryKey bit      NOT NULL,
    IndexType    tinyint  NOT NULL,
    HasFilter    bit      NOT NULL,
    ColumnName   sysname  NOT NULL,
    KeyOrdinal   tinyint  NOT NULL,
    IsIncluded   bit      NOT NULL,
    IsDescending bit      NOT NULL
);

/* No single-quoted literals inside the template, so no quote doubling is required. */
DECLARE @Template nvarchar(max) = N'
SELECT @dbName, s.name, t.name, i.name, i.object_id, i.index_id,
       i.is_unique, i.is_primary_key, i.type, i.has_filter,
       c.name, ic.key_ordinal, ic.is_included_column, ic.is_descending_key
FROM {DB}sys.indexes AS i
INNER JOIN {DB}sys.tables AS t ON t.object_id = i.object_id
INNER JOIN {DB}sys.schemas AS s ON s.schema_id = t.schema_id
INNER JOIN {DB}sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
INNER JOIN {DB}sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.type IN (1, 2)
  AND i.is_hypothetical = 0
  AND i.name IS NOT NULL
  AND t.is_ms_shipped = 0;';

DECLARE @DbName sysname;
DECLARE @Sql nvarchar(max);
DECLARE @SkippedDbs nvarchar(max) = N'';

IF @IsAzureSqlDb = 1
BEGIN
    SET @DbName = DB_NAME();
    SET @Sql = REPLACE(@Template, N'{DB}', N'');

    BEGIN TRY
        INSERT INTO #IndexColumns
            (DatabaseName, SchemaName, TableName, IndexName, ObjectId, IndexId,
             IsUnique, IsPrimaryKey, IndexType, HasFilter,
             ColumnName, KeyOrdinal, IsIncluded, IsDescending)
        EXEC sys.sp_executesql @Sql, N'@dbName sysname', @dbName = @DbName;
    END TRY
    BEGIN CATCH
        SET @SkippedDbs = @SkippedDbs + @DbName + N'; ';
    END CATCH
END
ELSE
BEGIN
    DECLARE DbCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.source_database_id IS NULL
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN DbCursor;
    FETCH NEXT FROM DbCursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Sql = REPLACE(@Template, N'{DB}', QUOTENAME(@DbName) + N'.');

        BEGIN TRY
            INSERT INTO #IndexColumns
                (DatabaseName, SchemaName, TableName, IndexName, ObjectId, IndexId,
                 IsUnique, IsPrimaryKey, IndexType, HasFilter,
                 ColumnName, KeyOrdinal, IsIncluded, IsDescending)
            EXEC sys.sp_executesql @Sql, N'@dbName sysname', @dbName = @DbName;
        END TRY
        BEGIN CATCH
            SET @SkippedDbs = @SkippedDbs + @DbName + N'; ';
        END CATCH

        FETCH NEXT FROM DbCursor INTO @DbName;
    END

    CLOSE DbCursor;
    DEALLOCATE DbCursor;
END

CREATE TABLE #IndexDef
(
    DatabaseName    sysname       NOT NULL,
    SchemaName      sysname       NOT NULL,
    TableName       sysname       NOT NULL,
    IndexName       sysname       NOT NULL,
    ObjectId        int           NOT NULL,
    IndexId         int           NOT NULL,
    IsUnique        bit           NOT NULL,
    IsPrimaryKey    bit           NOT NULL,
    HasFilter       bit           NOT NULL,
    KeyColumns      nvarchar(max) NOT NULL,
    IncludedColumns nvarchar(max) NOT NULL
);

/* Canonical signature per index: ordered key columns (with sort direction) and alphabetised included columns. */
INSERT INTO #IndexDef
    (DatabaseName, SchemaName, TableName, IndexName, ObjectId, IndexId,
     IsUnique, IsPrimaryKey, HasFilter, KeyColumns, IncludedColumns)
SELECT d.DatabaseName, d.SchemaName, d.TableName, d.IndexName, d.ObjectId, d.IndexId,
       d.IsUnique, d.IsPrimaryKey, d.HasFilter,
       ISNULL(STUFF((SELECT N',' + k.ColumnName + CASE WHEN k.IsDescending = 1 THEN N' DESC' ELSE N' ASC' END
                     FROM #IndexColumns AS k
                     WHERE k.DatabaseName = d.DatabaseName
                       AND k.ObjectId = d.ObjectId
                       AND k.IndexId = d.IndexId
                       AND k.IsIncluded = 0
                     ORDER BY k.KeyOrdinal
                     FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, N''), N''),
       ISNULL(STUFF((SELECT N',' + n.ColumnName
                     FROM #IndexColumns AS n
                     WHERE n.DatabaseName = d.DatabaseName
                       AND n.ObjectId = d.ObjectId
                       AND n.IndexId = d.IndexId
                       AND n.IsIncluded = 1
                     ORDER BY n.ColumnName
                     FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, N''), N'')
FROM (SELECT DISTINCT DatabaseName, SchemaName, TableName, IndexName,
                      ObjectId, IndexId, IsUnique, IsPrimaryKey, HasFilter
      FROM #IndexColumns) AS d;

CREATE TABLE #Redundant
(
    DatabaseName    sysname     NOT NULL,
    SchemaName      sysname     NOT NULL,
    TableName       sysname     NOT NULL,
    IndexName       sysname     NOT NULL,
    OverlappingWith sysname     NOT NULL,
    IssueType       varchar(20) NOT NULL
);

/* Exact duplicates: identical key list AND identical include list on the same table. */
INSERT INTO #Redundant (DatabaseName, SchemaName, TableName, IndexName, OverlappingWith, IssueType)
SELECT b.DatabaseName, b.SchemaName, b.TableName, b.IndexName, a.IndexName, 'DUPLICATE'
FROM #IndexDef AS a
INNER JOIN #IndexDef AS b
        ON b.DatabaseName = a.DatabaseName
       AND b.ObjectId = a.ObjectId
       AND b.IndexId > a.IndexId
WHERE a.HasFilter = 0
  AND b.HasFilter = 0
  AND a.KeyColumns = b.KeyColumns
  AND a.IncludedColumns = b.IncludedColumns
  AND a.KeyColumns <> N'';

/* Overlapping: a non-unique, non-clustered, include-free index whose keys are a strict leading prefix of another index. */
INSERT INTO #Redundant (DatabaseName, SchemaName, TableName, IndexName, OverlappingWith, IssueType)
SELECT a.DatabaseName, a.SchemaName, a.TableName, a.IndexName, b.IndexName, 'OVERLAPPING'
FROM #IndexDef AS a
INNER JOIN #IndexDef AS b
        ON b.DatabaseName = a.DatabaseName
       AND b.ObjectId = a.ObjectId
       AND b.IndexId <> a.IndexId
WHERE a.IsUnique = 0
  AND a.IsPrimaryKey = 0
  AND a.IndexId > 1
  AND a.HasFilter = 0
  AND b.HasFilter = 0
  AND a.IncludedColumns = N''
  AND a.KeyColumns <> N''
  AND LEN(a.KeyColumns) < LEN(b.KeyColumns)
  AND LEFT(b.KeyColumns, LEN(a.KeyColumns) + 1) = a.KeyColumns + N',';

DECLARE @DupCount int = (SELECT COUNT(*) FROM #Redundant WHERE IssueType = 'DUPLICATE');
DECLARE @OverlapCount int = (SELECT COUNT(*) FROM #Redundant WHERE IssueType = 'OVERLAPPING');
DECLARE @IndexCount int = (SELECT COUNT(*) FROM #IndexDef);
DECLARE @DbScanned int = (SELECT COUNT(DISTINCT DatabaseName) FROM #IndexColumns);

DECLARE @DbList nvarchar(max) =
    ISNULL(STUFF((SELECT DISTINCT N', ' + x.DatabaseName
                  FROM #IndexColumns AS x
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''),
           N'No accessible user databases');

DECLARE @Examples nvarchar(max) =
    ISNULL(STUFF((SELECT TOP (5) N'; ' + r.IssueType + N': ' + r.DatabaseName + N'.' + r.SchemaName + N'.'
                              + r.TableName + N' [' + r.IndexName + N'] vs [' + r.OverlappingWith + N']'
                  FROM #Redundant AS r
                  ORDER BY CASE WHEN r.IssueType = 'DUPLICATE' THEN 0 ELSE 1 END,
                           r.DatabaseName, r.SchemaName, r.TableName, r.IndexName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''),
           N'None');

DECLARE @Score int;
DECLARE @Result nvarchar(10);

IF @DbScanned = 0
    SET @Score = 1;
ELSE IF @DupCount > 0
    SET @Score = 1;
ELSE IF @OverlapCount > 0
    SET @Score = 2;
ELSE
    SET @Score = 3;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DECLARE @Finding nvarchar(max) =
      N'Scanned ' + CAST(@DbScanned AS nvarchar(20)) + N' user database(s) covering '
    + CAST(@IndexCount AS nvarchar(20)) + N' rowstore index(es). Exact duplicate index pairs: '
    + CAST(@DupCount AS nvarchar(20)) + N'. Overlapping (leading-key prefix) indexes: '
    + CAST(@OverlapCount AS nvarchar(20)) + N'. Examples: ' + @Examples + N'.'
    + CASE WHEN LEN(@SkippedDbs) > 0
           THEN N' Databases skipped because their metadata could not be read: ' + @SkippedDbs
           ELSE N'' END
    + CASE WHEN @DbScanned = 0
           THEN N' No user database index metadata could be read, so duplicate/overlapping index status could not be verified; manual review required.'
           ELSE N'' END
    + CASE WHEN @DbScanned > 0 AND @DupCount = 0 AND @OverlapCount = 0
           THEN N' No redundant, duplicate or overlapping indexes detected.'
           ELSE N'' END;

SELECT
    @Result  AS Result,
    @Score   AS Score,
    @DbList  AS DatabaseQueried,
    @Finding AS Finding;