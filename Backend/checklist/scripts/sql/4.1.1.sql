/*==============================================================================
  Checklist Item : 4.1.1
  Description    : Modeling approach is deliberate (3NF integration layer
                   and/or dimensional marts)
  Script Type    : SQL
  Scope          : SERVER (iterates accessible user databases)
  Read-Only      : Yes - catalog views only; writes nothing outside tempdb
  Compatibility  : SQL Server 2012+ and Azure SQL Database
==============================================================================*/
SET NOCOUNT ON;

DECLARE @Result          nvarchar(50)   = N'Needs Review';
DECLARE @Score           int            = 0;
DECLARE @DatabaseQueried nvarchar(max)  = N'(none)';
DECLARE @Finding         nvarchar(max)  = N'';

DECLARE @IsAzureDb bit =
        CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#Targets') IS NOT NULL DROP TABLE #Targets;
CREATE TABLE #Targets
(
    DatabaseName sysname NOT NULL PRIMARY KEY
);

IF OBJECT_ID('tempdb..#Model') IS NOT NULL DROP TABLE #Model;
CREATE TABLE #Model
(
    DatabaseName  sysname        NOT NULL PRIMARY KEY,
    UserTables    int            NULL,
    TablesWithPK  int            NULL,
    ForeignKeys   int            NULL,
    TablesWithFK  int            NULL,
    DimTables     int            NULL,
    FactTables    int            NULL,
    DateDimension int            NULL,
    LayerSchemas  int            NULL,
    ErrorMessage  nvarchar(1000) NULL
);

/* ---------- 1. Determine which databases to inspect ---------- */
IF @IsAzureDb = 1
BEGIN
    INSERT INTO #Targets (DatabaseName)
    VALUES (DB_NAME());
END
ELSE
BEGIN
    INSERT INTO #Targets (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0                       /* ONLINE only */
      AND d.source_database_id IS NULL      /* exclude snapshots */
      AND d.name NOT IN (N'ReportServer', N'ReportServerTempDB', N'SSISDB', N'distribution')
      AND HAS_DBACCESS(d.name) = 1;
END

/* ---------- 2. Collect modelling artifacts per database ---------- */
DECLARE @db     sysname,
        @prefix nvarchar(300),
        @sql    nvarchar(max);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #Targets ORDER BY DatabaseName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @prefix = CASE WHEN @IsAzureDb = 1 THEN N'' ELSE QUOTENAME(@db) + N'.' END;

        SET @sql = N'
WITH t AS
(
    SELECT s.name AS SchemaName, tb.name AS TableName, tb.object_id
    FROM ' + @prefix + N'sys.tables AS tb
    INNER JOIN ' + @prefix + N'sys.schemas AS s ON s.schema_id = tb.schema_id
    WHERE tb.is_ms_shipped = 0
      AND tb.name <> ''sysdiagrams''
),
pk AS
(
    SELECT DISTINCT kc.parent_object_id
    FROM ' + @prefix + N'sys.key_constraints AS kc
    WHERE kc.type = ''PK''
),
fk AS
(
    SELECT f.object_id, f.parent_object_id
    FROM ' + @prefix + N'sys.foreign_keys AS f
)
INSERT INTO #Model
      (DatabaseName, UserTables, TablesWithPK, ForeignKeys, TablesWithFK,
       DimTables, FactTables, DateDimension, LayerSchemas)
SELECT
    @dbname,
    (SELECT COUNT(*) FROM t),
    (SELECT COUNT(*) FROM t WHERE t.object_id IN (SELECT parent_object_id FROM pk)),
    (SELECT COUNT(*) FROM fk WHERE fk.parent_object_id IN (SELECT object_id FROM t)),
    (SELECT COUNT(DISTINCT fk.parent_object_id) FROM fk WHERE fk.parent_object_id IN (SELECT object_id FROM t)),
    (SELECT COUNT(*) FROM t
      WHERE t.TableName LIKE ''Dim%''
         OR t.TableName LIKE ''D[_]%''
         OR t.TableName LIKE ''%[_]Dim''
         OR t.TableName LIKE ''%Dimension''
         OR t.SchemaName IN (''dim'', ''dims'', ''dimension'', ''dimensions'')),
    (SELECT COUNT(*) FROM t
      WHERE t.TableName LIKE ''Fact%''
         OR t.TableName LIKE ''F[_]%''
         OR t.TableName LIKE ''%[_]Fact''
         OR t.SchemaName IN (''fact'', ''facts'')),
    (SELECT COUNT(*) FROM t
      WHERE (t.TableName LIKE ''%Date%'' OR t.TableName LIKE ''%Calendar%'')
        AND (t.TableName LIKE ''Dim%'' OR t.SchemaName IN (''dim'', ''dims'', ''dimension'', ''dimensions''))),
    (SELECT COUNT(DISTINCT t.SchemaName) FROM t
      WHERE t.SchemaName IN (''stg'', ''staging'', ''ods'', ''edw'', ''dw'', ''dwh'',
                             ''mart'', ''marts'', ''datamart'', ''dim'', ''dims'',
                             ''dimension'', ''dimensions'', ''fact'', ''facts'',
                             ''integration'', ''raw'', ''curated'', ''core'',
                             ''presentation'', ''landing''));';

        EXEC sys.sp_executesql @sql, N'@dbname sysname', @dbname = @db;
    END TRY
    BEGIN CATCH
        IF NOT EXISTS (SELECT 1 FROM #Model WHERE DatabaseName = @db)
            INSERT INTO #Model (DatabaseName, ErrorMessage)
            VALUES (@db, LEFT(ERROR_MESSAGE(), 1000));
    END CATCH

    FETCH NEXT FROM db_cursor INTO @db;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

/* ---------- 3. Score each database ---------- */
IF OBJECT_ID('tempdb..#Scored') IS NOT NULL DROP TABLE #Scored;
CREATE TABLE #Scored
(
    DatabaseName sysname        NOT NULL PRIMARY KEY,
    DbScore      int            NOT NULL,
    Detail       nvarchar(1500) NOT NULL
);

INSERT INTO #Scored (DatabaseName, DbScore, Detail)
SELECT
    m.DatabaseName,
    c.DbScore,
    CASE
        WHEN m.ErrorMessage IS NOT NULL
            THEN m.DatabaseName + N': could not be inspected (' + m.ErrorMessage + N')'
        WHEN ISNULL(m.UserTables, 0) = 0
            THEN m.DatabaseName + N': no user tables, nothing to assess'
        ELSE
            m.DatabaseName + N': tables=' + CONVERT(nvarchar(12), m.UserTables)
            + N', PK coverage=' + CONVERT(nvarchar(12), m.TablesWithPK * 100 / m.UserTables) + N'%'
            + N', FKs=' + CONVERT(nvarchar(12), m.ForeignKeys)
            + N' over ' + CONVERT(nvarchar(12), m.TablesWithFK * 100 / m.UserTables) + N'% of tables'
            + N', dim-named=' + CONVERT(nvarchar(12), m.DimTables)
            + N', fact-named=' + CONVERT(nvarchar(12), m.FactTables)
            + N', date dimension=' + CASE WHEN m.DateDimension > 0 THEN N'Yes' ELSE N'No' END
            + N', modelling-layer schemas=' + CONVERT(nvarchar(12), m.LayerSchemas)
            + N' ['
            + CASE c.DbScore
                WHEN 3 THEN N'deliberate model evident'
                WHEN 2 THEN N'partial evidence only'
                ELSE N'no deliberate model evident'
              END
            + N']'
    END
FROM #Model AS m
CROSS APPLY
(
    SELECT DbScore =
        CASE
            WHEN m.ErrorMessage IS NOT NULL OR ISNULL(m.UserTables, 0) = 0 THEN 0
            WHEN (m.DimTables >= 2 AND m.FactTables >= 1)
              OR (m.UserTables >= 5
                  AND m.TablesWithPK * 100 / m.UserTables >= 80
                  AND m.TablesWithFK * 100 / m.UserTables >= 50) THEN 3
            WHEN m.DimTables >= 1
              OR m.FactTables >= 1
              OR m.LayerSchemas >= 1
              OR (m.TablesWithPK * 100 / m.UserTables >= 60 AND m.ForeignKeys > 0) THEN 2
            ELSE 1
        END
) AS c;

/* ---------- 4. Roll up to a single server-level verdict ---------- */
IF NOT EXISTS (SELECT 1 FROM #Scored)
BEGIN
    SET @Score           = 0;
    SET @Result          = N'Needs Review';
    SET @DatabaseQueried = N'(none)';
    SET @Finding         = N'No accessible user databases were found, so the modelling approach could not be assessed.';
END
ELSE
BEGIN
    SELECT @Score = MIN(s.DbScore) FROM #Scored AS s;

    SET @Result = CASE @Score
                      WHEN 3 THEN N'Pass'
                      WHEN 2 THEN N'Partial'
                      WHEN 1 THEN N'Fail'
                      ELSE N'Needs Review'
                  END;

    SELECT @DatabaseQueried = STUFF((
        SELECT N', ' + s.DatabaseName
        FROM #Scored AS s
        ORDER BY s.DatabaseName
        FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'');

    SELECT @Finding =
        N'Databases inspected: ' + CONVERT(nvarchar(12), COUNT(*))
        + N' (score 3: ' + CONVERT(nvarchar(12), SUM(CASE WHEN s.DbScore = 3 THEN 1 ELSE 0 END))
        + N', score 2: ' + CONVERT(nvarchar(12), SUM(CASE WHEN s.DbScore = 2 THEN 1 ELSE 0 END))
        + N', score 1: ' + CONVERT(nvarchar(12), SUM(CASE WHEN s.DbScore = 1 THEN 1 ELSE 0 END))
        + N', score 0: ' + CONVERT(nvarchar(12), SUM(CASE WHEN s.DbScore = 0 THEN 1 ELSE 0 END))
        + N'). '
    FROM #Scored AS s;

    SET @Finding = @Finding
        + CASE @Score
            WHEN 3 THEN N'Every database shows a deliberate modelling approach - dimensional star-schema artifacts and/or a normalised, key-enforced integration layer. '
            WHEN 2 THEN N'At least one database shows only partial evidence of a deliberate model (some dimensional naming, modelling-layer schemas or key discipline, but not a consistent 3NF or dimensional design). '
            WHEN 1 THEN N'At least one database shows no evidence of a deliberate modelling approach - no dimensional artifacts, no modelling-layer schemas and negligible primary/foreign key discipline. '
            ELSE N'At least one database has no user tables or could not be inspected, so the modelling approach cannot be confirmed. '
          END
        + N'Per-database evidence: '
        + ISNULL(STUFF((
            SELECT N' | ' + s.Detail
            FROM #Scored AS s
            ORDER BY s.DbScore, s.DatabaseName
            FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 3, N''), N'none');
END

IF OBJECT_ID('tempdb..#Scored')  IS NOT NULL DROP TABLE #Scored;
IF OBJECT_ID('tempdb..#Model')   IS NOT NULL DROP TABLE #Model;
IF OBJECT_ID('tempdb..#Targets') IS NOT NULL DROP TABLE #Targets;

/* ---------- 5. Standard four-column output ---------- */
SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;