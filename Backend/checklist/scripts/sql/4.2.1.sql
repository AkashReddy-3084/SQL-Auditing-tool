SET NOCOUNT ON;

/* Checklist 4.2.1 - Star schema implemented (fact + dimension tables, not flat wide tables)
   Strictly read-only: only catalog views are read; temp tables are used for staging. */

DECLARE @Result NVARCHAR(20);
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(256) = N'None';
DECLARE @Finding NVARCHAR(4000) = N'No database found to be queried';

IF OBJECT_ID('tempdb..#Databases') IS NOT NULL DROP TABLE #Databases;
IF OBJECT_ID('tempdb..#TableProfile') IS NOT NULL DROP TABLE #TableProfile;
IF OBJECT_ID('tempdb..#FkLink') IS NOT NULL DROP TABLE #FkLink;
IF OBJECT_ID('tempdb..#DbScore') IS NOT NULL DROP TABLE #DbScore;

CREATE TABLE #Databases
(
    DbName SYSNAME NOT NULL PRIMARY KEY,
    Profiled BIT NOT NULL DEFAULT (0)
);

CREATE TABLE #TableProfile
(
    DbName       SYSNAME  NOT NULL,
    ObjectId     INT      NOT NULL,
    SchemaName   SYSNAME  NOT NULL,
    TableName    SYSNAME  NOT NULL,
    ColumnCount  INT      NOT NULL,
    OutgoingFKs  INT      NOT NULL,
    IncomingFKs  INT      NOT NULL,
    RowCountEst  BIGINT   NOT NULL,
    NameIsFact   BIT      NOT NULL,
    NameIsDim    BIT      NOT NULL,
    IsFact       BIT      NOT NULL DEFAULT (0),
    IsDim        BIT      NOT NULL DEFAULT (0)
);

CREATE TABLE #FkLink
(
    DbName             SYSNAME NOT NULL,
    ParentObjectId     INT     NOT NULL,
    ReferencedObjectId INT     NOT NULL
);

CREATE TABLE #DbScore
(
    DbName         SYSNAME NOT NULL,
    UserTableCount INT     NOT NULL,
    FactTables     INT     NOT NULL,
    DimTables      INT     NOT NULL,
    FlatWideTables INT     NOT NULL,
    StarLinks      INT     NOT NULL,
    MaxFactRows    BIGINT  NOT NULL,
    DbScore        INT     NOT NULL
);

INSERT INTO #Databases (DbName)
SELECT d.name
FROM sys.databases AS d
WHERE d.database_id > 4
  AND d.name NOT IN ('master', 'model', 'msdb', 'tempdb')
  AND d.state = 0
  AND HAS_DBACCESS(d.name) = 1;

DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DbName FROM #Databases ORDER BY DbName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'
INSERT INTO #TableProfile (DbName, ObjectId, SchemaName, TableName, ColumnCount, OutgoingFKs, IncomingFKs, RowCountEst, NameIsFact, NameIsDim)
SELECT ' + QUOTENAME(@DbName, '''') + N',
    t.object_id,
    s.name,
    t.name,
    ISNULL((SELECT COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.columns c WHERE c.object_id = t.object_id), 0),
    ISNULL((SELECT COUNT(DISTINCT fk.referenced_object_id) FROM ' + QUOTENAME(@DbName) + N'.sys.foreign_keys fk WHERE fk.parent_object_id = t.object_id), 0),
    ISNULL((SELECT COUNT(DISTINCT fk2.parent_object_id) FROM ' + QUOTENAME(@DbName) + N'.sys.foreign_keys fk2 WHERE fk2.referenced_object_id = t.object_id), 0),
    ISNULL((SELECT SUM(p.rows) FROM ' + QUOTENAME(@DbName) + N'.sys.partitions p WHERE p.object_id = t.object_id AND p.index_id IN (0, 1)), 0),
    CASE WHEN t.name LIKE ''Fact%'' OR t.name LIKE ''F[_]%'' OR t.name LIKE ''%[_]Fact'' OR t.name LIKE ''%Facts'' THEN 1 ELSE 0 END,
    CASE WHEN t.name LIKE ''Dim%'' OR t.name LIKE ''D[_]%'' OR t.name LIKE ''%[_]Dim'' OR t.name LIKE ''%Dimension'' THEN 1 ELSE 0 END
FROM ' + QUOTENAME(@DbName) + N'.sys.tables AS t
INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas AS s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
  AND t.type = ''U''
  AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'');

INSERT INTO #FkLink (DbName, ParentObjectId, ReferencedObjectId)
SELECT ' + QUOTENAME(@DbName, '''') + N', fk.parent_object_id, fk.referenced_object_id
FROM ' + QUOTENAME(@DbName) + N'.sys.foreign_keys AS fk;';

        EXEC sys.sp_executesql @Sql;

        UPDATE #Databases SET Profiled = 1 WHERE DbName = @DbName;
    END TRY
    BEGIN CATCH
        /* Database unreadable for this login - leave it unprofiled and continue. */
        UPDATE #Databases SET Profiled = 0 WHERE DbName = @DbName;
    END CATCH

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

/* Classify: explicit naming first, then relationship shape. */
UPDATE #TableProfile SET IsDim = 1 WHERE NameIsDim = 1;
UPDATE #TableProfile SET IsFact = 1 WHERE NameIsFact = 1 AND IsDim = 0;
UPDATE #TableProfile SET IsFact = 1 WHERE IsFact = 0 AND IsDim = 0 AND OutgoingFKs >= 2;
UPDATE #TableProfile SET IsDim = 1 WHERE IsFact = 0 AND IsDim = 0 AND IncomingFKs >= 1 AND ColumnCount <= 40;

INSERT INTO #DbScore (DbName, UserTableCount, FactTables, DimTables, FlatWideTables, StarLinks, MaxFactRows, DbScore)
SELECT
    d.DbName,
    agg.UserTableCount,
    agg.FactTables,
    agg.DimTables,
    agg.FlatWideTables,
    ISNULL(lnk.StarLinks, 0),
    agg.MaxFactRows,
    CASE
        WHEN agg.FactTables >= 1 AND agg.DimTables >= 2 AND ISNULL(lnk.StarLinks, 0) >= 2 AND agg.FlatWideTables * 2 <= agg.UserTableCount THEN 3
        WHEN agg.FactTables >= 1 AND agg.DimTables >= 1 THEN 2
        WHEN agg.FactTables >= 1 OR agg.DimTables >= 1 THEN 1
        ELSE 0
    END
FROM #Databases AS d
CROSS APPLY
(
    SELECT
        COUNT(*) AS UserTableCount,
        ISNULL(SUM(CASE WHEN tp.IsFact = 1 THEN 1 ELSE 0 END), 0) AS FactTables,
        ISNULL(SUM(CASE WHEN tp.IsDim = 1 THEN 1 ELSE 0 END), 0) AS DimTables,
        ISNULL(SUM(CASE WHEN tp.ColumnCount >= 30 AND tp.OutgoingFKs = 0 AND tp.IncomingFKs = 0 THEN 1 ELSE 0 END), 0) AS FlatWideTables,
        ISNULL(MAX(CASE WHEN tp.IsFact = 1 THEN tp.RowCountEst ELSE 0 END), 0) AS MaxFactRows
    FROM #TableProfile AS tp
    WHERE tp.DbName = d.DbName
) AS agg
OUTER APPLY
(
    SELECT COUNT(*) AS StarLinks
    FROM #FkLink AS fk
    INNER JOIN #TableProfile AS pf
        ON pf.DbName = fk.DbName AND pf.ObjectId = fk.ParentObjectId
    INNER JOIN #TableProfile AS pr
        ON pr.DbName = fk.DbName AND pr.ObjectId = fk.ReferencedObjectId
    WHERE fk.DbName = d.DbName
      AND pf.IsFact = 1
      AND pr.IsDim = 1
) AS lnk
WHERE d.Profiled = 1;

IF EXISTS (SELECT 1 FROM #DbScore)
BEGIN
    DECLARE @BestDb         SYSNAME;
    DECLARE @BestScore      INT;
    DECLARE @BestTables     INT;
    DECLARE @BestFacts      INT;
    DECLARE @BestDims       INT;
    DECLARE @BestFlatWide   INT;
    DECLARE @BestStarLinks  INT;
    DECLARE @BestMaxRows    BIGINT;
    DECLARE @DbCount        INT;
    DECLARE @Breakdown      NVARCHAR(2000) = N'';

    SELECT @DbCount = COUNT(*) FROM #DbScore;

    SELECT TOP (1)
        @BestDb        = DbName,
        @BestScore     = DbScore,
        @BestTables    = UserTableCount,
        @BestFacts     = FactTables,
        @BestDims      = DimTables,
        @BestFlatWide  = FlatWideTables,
        @BestStarLinks = StarLinks,
        @BestMaxRows   = MaxFactRows
    FROM #DbScore
    ORDER BY DbScore DESC, StarLinks DESC, UserTableCount DESC, DbName;

    SELECT TOP (10) @Breakdown = @Breakdown
        + CASE WHEN @Breakdown = N'' THEN N'' ELSE N'; ' END
        + DbName + N' (facts=' + CAST(FactTables AS NVARCHAR(20))
        + N', dims=' + CAST(DimTables AS NVARCHAR(20))
        + N', fact-to-dim FKs=' + CAST(StarLinks AS NVARCHAR(20))
        + N', flat wide=' + CAST(FlatWideTables AS NVARCHAR(20))
        + N'/' + CAST(UserTableCount AS NVARCHAR(20)) + N' tables)'
    FROM #DbScore
    ORDER BY DbScore DESC, StarLinks DESC, UserTableCount DESC, DbName;

    SET @Score = @BestScore;
    SET @DatabaseQueried = @BestDb;

    IF @BestScore = 3
        SET @Finding = N'Star schema implemented in [' + @BestDb + N']: ' + CAST(@BestFacts AS NVARCHAR(20))
                     + N' fact table(s) and ' + CAST(@BestDims AS NVARCHAR(20))
                     + N' dimension table(s) out of ' + CAST(@BestTables AS NVARCHAR(20))
                     + N' user tables, joined by ' + CAST(@BestStarLinks AS NVARCHAR(20))
                     + N' enforced fact-to-dimension foreign key(s); largest fact table holds approximately '
                     + CAST(@BestMaxRows AS NVARCHAR(30)) + N' rows and flat wide tables (30+ columns, no relationships) number '
                     + CAST(@BestFlatWide AS NVARCHAR(20)) + N'. Databases profiled: ' + CAST(@DbCount AS NVARCHAR(20))
                     + N'. Breakdown: ' + @Breakdown + N'.';
    ELSE IF @BestScore = 2
        SET @Finding = N'Partial star schema in [' + @BestDb + N']: ' + CAST(@BestFacts AS NVARCHAR(20))
                     + N' fact table(s) and ' + CAST(@BestDims AS NVARCHAR(20))
                     + N' dimension table(s) out of ' + CAST(@BestTables AS NVARCHAR(20))
                     + N' user tables, but only ' + CAST(@BestStarLinks AS NVARCHAR(20))
                     + N' enforced fact-to-dimension foreign key(s) (at least 2 dimensions and 2 links expected) and '
                     + CAST(@BestFlatWide AS NVARCHAR(20)) + N' flat wide table(s). Databases profiled: '
                     + CAST(@DbCount AS NVARCHAR(20)) + N'. Breakdown: ' + @Breakdown + N'.';
    ELSE IF @BestScore = 1
        SET @Finding = N'Dimensional modelling is not established; best candidate [' + @BestDb + N'] has only '
                     + CAST(@BestFacts AS NVARCHAR(20)) + N' fact table(s) and ' + CAST(@BestDims AS NVARCHAR(20))
                     + N' dimension table(s) across ' + CAST(@BestTables AS NVARCHAR(20))
                     + N' user tables, with ' + CAST(@BestStarLinks AS NVARCHAR(20))
                     + N' fact-to-dimension foreign key(s) and ' + CAST(@BestFlatWide AS NVARCHAR(20))
                     + N' flat wide table(s). Databases profiled: ' + CAST(@DbCount AS NVARCHAR(20))
                     + N'. Breakdown: ' + @Breakdown + N'.';
    ELSE
        SET @Finding = N'No star schema found in any of the ' + CAST(@DbCount AS NVARCHAR(20))
                     + N' profiled user database(s): no table qualifies as a fact table (Fact naming or 2+ outgoing foreign keys) or a dimension table (Dim naming or referenced by another table). Best candidate [' + @BestDb
                     + N'] has ' + CAST(@BestTables AS NVARCHAR(20)) + N' user table(s) of which '
                     + CAST(@BestFlatWide AS NVARCHAR(20))
                     + N' are flat and wide (30+ columns, no foreign key relationships), indicating a denormalised model. Breakdown: '
                     + @Breakdown + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#Databases') IS NOT NULL DROP TABLE #Databases;
IF OBJECT_ID('tempdb..#TableProfile') IS NOT NULL DROP TABLE #TableProfile;
IF OBJECT_ID('tempdb..#FkLink') IS NOT NULL DROP TABLE #FkLink;
IF OBJECT_ID('tempdb..#DbScore') IS NOT NULL DROP TABLE #DbScore;