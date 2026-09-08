/* Checklist 4.2.7 - SCD strategy defined and implemented per dimension (Type 1/2/3)
   Read-only catalog inspection: classifies dimension tables by the SCD artifacts present. */
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

IF OBJECT_ID('tempdb..#DimAudit') IS NOT NULL DROP TABLE #DimAudit;
IF OBJECT_ID('tempdb..#DimClass') IS NOT NULL DROP TABLE #DimClass;
IF OBJECT_ID('tempdb..#ScannedDb') IS NOT NULL DROP TABLE #ScannedDb;

CREATE TABLE #DimAudit
(
    DatabaseName   SYSNAME NOT NULL,
    SchemaName     SYSNAME NOT NULL,
    TableName      SYSNAME NOT NULL,
    IsTemporal     INT     NOT NULL,
    HasStartCol    INT     NOT NULL,
    HasEndCol      INT     NOT NULL,
    HasCurrentFlag INT     NOT NULL,
    HasVersionCol  INT     NOT NULL,
    HasType3Col    INT     NOT NULL
);

CREATE TABLE #DimClass
(
    DatabaseName SYSNAME     NOT NULL,
    SchemaName   SYSNAME     NOT NULL,
    TableName    SYSNAME     NOT NULL,
    SCDClass     VARCHAR(30) NOT NULL
);

CREATE TABLE #ScannedDb (DatabaseName SYSNAME NOT NULL);

DECLARE @EngineEdition  INT           = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @HasTemporal    BIT           = CASE WHEN COL_LENGTH('sys.tables', 'temporal_type') IS NOT NULL THEN 1 ELSE 0 END;
DECLARE @TemporalExpr   NVARCHAR(200) = CASE WHEN @HasTemporal = 1 THEN N'CASE WHEN t.temporal_type = 2 THEN 1 ELSE 0 END' ELSE N'0' END;
DECLARE @TemporalFilter NVARCHAR(100) = CASE WHEN @HasTemporal = 1 THEN N' AND t.temporal_type <> 1' ELSE N'' END;

DECLARE @Stmt NVARCHAR(MAX) =
N'SET NOCOUNT ON;
INSERT INTO #DimAudit (DatabaseName, SchemaName, TableName, IsTemporal, HasStartCol, HasEndCol, HasCurrentFlag, HasVersionCol, HasType3Col)
SELECT
    DB_NAME(),
    s.name,
    t.name,
    MAX(' + @TemporalExpr + N'),
    MAX(CASE WHEN c.name LIKE ''%EffectiveFrom%'' OR c.name LIKE ''%EffectiveDate%'' OR c.name LIKE ''%EffectiveStart%''
                  OR c.name LIKE ''%StartDate%'' OR c.name LIKE ''%ValidFrom%'' OR c.name LIKE ''%RowStart%''
                  OR c.name LIKE ''%DateFrom%'' OR c.name LIKE ''%FromDate%'' OR c.name LIKE ''%BeginDate%''
             THEN 1 ELSE 0 END),
    MAX(CASE WHEN c.name LIKE ''%EffectiveTo%'' OR c.name LIKE ''%EffectiveEnd%'' OR c.name LIKE ''%EndDate%''
                  OR c.name LIKE ''%ValidTo%'' OR c.name LIKE ''%RowEnd%'' OR c.name LIKE ''%DateTo%''
                  OR c.name LIKE ''%ToDate%'' OR c.name LIKE ''%ExpiryDate%'' OR c.name LIKE ''%ExpirationDate%''
             THEN 1 ELSE 0 END),
    MAX(CASE WHEN c.name LIKE ''%IsCurrent%'' OR c.name LIKE ''%CurrentFlag%'' OR c.name LIKE ''%CurrentInd%''
                  OR c.name LIKE ''%CurrentRecord%'' OR c.name LIKE ''%RowIsCurrent%'' OR c.name LIKE ''%IsLatest%''
                  OR c.name LIKE ''%ActiveFlag%'' OR c.name LIKE ''%IsActive%''
             THEN 1 ELSE 0 END),
    MAX(CASE WHEN c.name LIKE ''%SCDVersion%'' OR c.name LIKE ''%RowVersion%'' OR c.name LIKE ''%VersionNumber%''
                  OR c.name LIKE ''%RecordVersion%''
             THEN 1 ELSE 0 END),
    MAX(CASE WHEN c.name LIKE ''Prev[_]%'' OR c.name LIKE ''Previous%'' OR c.name LIKE ''Prior%''
                  OR c.name LIKE ''%[_]Previous'' OR c.name LIKE ''%[_]Prior''
             THEN 1 ELSE 0 END)
FROM sys.tables AS t
INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
LEFT JOIN sys.columns AS c ON c.object_id = t.object_id
WHERE t.is_ms_shipped = 0
  AND (t.name LIKE ''Dim%'' OR t.name LIKE ''D[_]%'' OR t.name LIKE ''%[_]Dim'' OR t.name LIKE ''%Dimension%''
       OR s.name IN (''dim'', ''dims'', ''dimension'', ''dimensions''))' + @TemporalFilter + N'
GROUP BY s.name, t.name;';

IF @EngineEdition IN (5, 6, 9, 11)
BEGIN
    /* Azure SQL Database / Synapse / Fabric: no cross-database context switching. */
    BEGIN TRY
        EXEC sys.sp_executesql @Stmt;
        INSERT INTO #ScannedDb (DatabaseName) VALUES (DB_NAME());
    END TRY
    BEGIN CATCH
        PRINT 'Skipped current database: ' + ERROR_MESSAGE();
    END CATCH
END
ELSE
BEGIN
    DECLARE @db   SYSNAME;
    DECLARE @Exec NVARCHAR(400);

    DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state_desc = 'ONLINE'
          AND d.source_database_id IS NULL
          AND HAS_DBACCESS(d.name) = 1
          AND d.name NOT IN ('distribution', 'SSISDB', 'ReportServer', 'ReportServerTempDB')
        ORDER BY d.name;

    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Exec = QUOTENAME(@db) + N'.sys.sp_executesql';
            EXEC @Exec @Stmt;
            INSERT INTO #ScannedDb (DatabaseName) VALUES (@db);
        END TRY
        BEGIN CATCH
            PRINT 'Skipped database ' + @db + ': ' + ERROR_MESSAGE();
        END CATCH

        FETCH NEXT FROM db_cur INTO @db;
    END

    CLOSE db_cur;
    DEALLOCATE db_cur;
END

INSERT INTO #DimClass (DatabaseName, SchemaName, TableName, SCDClass)
SELECT
    a.DatabaseName,
    a.SchemaName,
    a.TableName,
    CASE
        WHEN a.IsTemporal = 1 THEN 'Type 2 (temporal)'
        WHEN (a.HasStartCol = 1 AND a.HasEndCol = 1)
          OR (a.HasStartCol = 1 AND a.HasCurrentFlag = 1)
          OR (a.HasEndCol = 1 AND a.HasCurrentFlag = 1) THEN 'Type 2'
        WHEN a.HasType3Col = 1 THEN 'Type 3'
        WHEN a.HasStartCol = 1 OR a.HasEndCol = 1 OR a.HasCurrentFlag = 1 OR a.HasVersionCol = 1 THEN 'Type 2 (incomplete)'
        ELSE 'Type 1 / no history'
    END
FROM #DimAudit AS a;

DECLARE @Total      INT,
        @Type2      INT,
        @Type3      INT,
        @Incomplete INT,
        @NoHistory  INT,
        @Managed    INT,
        @Pct        INT,
        @DbCount    INT;

SELECT
    @Total      = COUNT(*),
    @Type2      = SUM(CASE WHEN SCDClass IN ('Type 2', 'Type 2 (temporal)') THEN 1 ELSE 0 END),
    @Type3      = SUM(CASE WHEN SCDClass = 'Type 3' THEN 1 ELSE 0 END),
    @Incomplete = SUM(CASE WHEN SCDClass = 'Type 2 (incomplete)' THEN 1 ELSE 0 END),
    @NoHistory  = SUM(CASE WHEN SCDClass = 'Type 1 / no history' THEN 1 ELSE 0 END)
FROM #DimClass;

SELECT @DbCount = COUNT(*) FROM #ScannedDb;

SET @Total      = ISNULL(@Total, 0);
SET @Type2      = ISNULL(@Type2, 0);
SET @Type3      = ISNULL(@Type3, 0);
SET @Incomplete = ISNULL(@Incomplete, 0);
SET @NoHistory  = ISNULL(@NoHistory, 0);
SET @Managed    = @Type2 + @Type3;
SET @Pct        = CASE WHEN @Total = 0 THEN 0 ELSE (@Managed * 100) / @Total END;

DECLARE @Unmanaged NVARCHAR(MAX) =
    STUFF((SELECT TOP (10) ', ' + x.DatabaseName + '.' + x.SchemaName + '.' + x.TableName + ' (' + x.SCDClass + ')'
           FROM #DimClass AS x
           WHERE x.SCDClass IN ('Type 1 / no history', 'Type 2 (incomplete)')
           ORDER BY x.DatabaseName, x.SchemaName, x.TableName
           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '');

DECLARE @Score           INT,
        @Result          VARCHAR(20),
        @DatabaseQueried NVARCHAR(MAX),
        @Finding         NVARCHAR(MAX);

IF @DbCount = 0
BEGIN
    SET @DatabaseQueried = 'None';
    SET @Finding = 'No database found to be queried';
    SET @Score = 0;
END
ELSE
BEGIN
    SET @DatabaseQueried =
        CASE
            WHEN @DbCount <= 5 THEN
                STUFF((SELECT ', ' + d.DatabaseName
                       FROM #ScannedDb AS d
                       ORDER BY d.DatabaseName
                       FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
            ELSE CAST(@DbCount AS VARCHAR(10)) + ' user databases scanned'
        END;

    IF @Total = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No dimension tables could be identified by naming convention (Dim*, D_*, *_Dim, *Dimension*, or dim/dimension schemas) across '
                     + CAST(@DbCount AS VARCHAR(10)) + ' scanned database(s), so no per-dimension SCD strategy is evidenced in the catalog. '
                     + 'Confirm the dimensional model and its documented Type 1/2/3 design.';
    END
    ELSE
    BEGIN
        SET @Finding = CAST(@Total AS VARCHAR(10)) + ' dimension table(s) inspected across ' + CAST(@DbCount AS VARCHAR(10)) + ' database(s): '
                     + CAST(@Type2 AS VARCHAR(10)) + ' with a complete Type 2 implementation (system-versioned temporal, or effective-from/effective-to/current-flag columns), '
                     + CAST(@Type3 AS VARCHAR(10)) + ' with Type 3 prior-value columns, '
                     + CAST(@Incomplete AS VARCHAR(10)) + ' with an incomplete Type 2 pattern (only one history column present), and '
                     + CAST(@NoHistory AS VARCHAR(10)) + ' with no history-tracking columns (Type 1 or unmanaged). Explicit SCD coverage: '
                     + CAST(@Pct AS VARCHAR(10)) + '%.';

        IF @Unmanaged IS NOT NULL
            SET @Finding = @Finding + ' Dimensions without a complete SCD implementation (up to 10 shown): ' + @Unmanaged + '.';

        SET @Finding = @Finding + ' Note: Type 1 is a legitimate strategy but is indistinguishable in the catalog from an undefined one, '
                     + 'so the documented per-dimension SCD design should be reviewed alongside this result.';

        IF @Pct = 100      SET @Score = 3;
        ELSE IF @Pct >= 75 SET @Score = 2;
        ELSE IF @Pct >= 40 SET @Score = 1;
        ELSE               SET @Score = 0;
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

DROP TABLE #DimClass;
DROP TABLE #DimAudit;
DROP TABLE #ScannedDb;