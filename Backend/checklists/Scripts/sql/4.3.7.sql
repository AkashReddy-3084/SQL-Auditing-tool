SET NOCOUNT ON;

/* Checklist 4.3.7 - Fill factor and index options set deliberately where needed. Read-only. */

DECLARE @IsAzureSqlDb bit = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;

IF OBJECT_ID('tempdb..#IndexOptions') IS NOT NULL DROP TABLE #IndexOptions;
IF OBJECT_ID('tempdb..#DbScanned') IS NOT NULL DROP TABLE #DbScanned;

CREATE TABLE #IndexOptions
(
    DatabaseName    sysname       NOT NULL,
    SchemaName      sysname       NOT NULL,
    TableName       sysname       NOT NULL,
    IndexName       sysname       NULL,
    IndexType       nvarchar(60)  NULL,
    FillFactorValue tinyint       NULL,
    IsPadded        bit           NULL,
    AllowPageLocks  bit           NULL,
    AllowRowLocks   bit           NULL
);

CREATE TABLE #DbScanned
(
    DatabaseName sysname NOT NULL
);

DECLARE @DbName sysname;
DECLARE @Sql    nvarchar(max);

IF @IsAzureSqlDb = 1
BEGIN
    INSERT INTO #DbScanned (DatabaseName)
    SELECT DB_NAME();

    INSERT INTO #IndexOptions (DatabaseName, SchemaName, TableName, IndexName, IndexType, FillFactorValue, IsPadded, AllowPageLocks, AllowRowLocks)
    SELECT DB_NAME(), s.name, t.name, i.name, i.type_desc, i.fill_factor, i.is_padded, i.allow_page_locks, i.allow_row_locks
    FROM sys.indexes AS i
    INNER JOIN sys.tables AS t ON t.object_id = i.object_id
    INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE i.type IN (1, 2)
      AND i.is_hypothetical = 0
      AND t.is_ms_shipped = 0;
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.source_database_id IS NULL
          AND d.is_read_only = 0
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'INSERT INTO #IndexOptions (DatabaseName, SchemaName, TableName, IndexName, IndexType, FillFactorValue, IsPadded, AllowPageLocks, AllowRowLocks) '
                     + N'SELECT ' + QUOTENAME(@DbName, '''') + N', s.name, t.name, i.name, i.type_desc, i.fill_factor, i.is_padded, i.allow_page_locks, i.allow_row_locks '
                     + N'FROM ' + QUOTENAME(@DbName) + N'.sys.indexes AS i '
                     + N'INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.tables AS t ON t.object_id = i.object_id '
                     + N'INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas AS s ON s.schema_id = t.schema_id '
                     + N'WHERE i.type IN (1, 2) AND i.is_hypothetical = 0 AND t.is_ms_shipped = 0;';

            EXEC sp_executesql @Sql;

            INSERT INTO #DbScanned (DatabaseName) VALUES (@DbName);
        END TRY
        BEGIN CATCH
            /* Database unreadable (offline, restoring, insufficient permission) - skip it. */
            SET @Sql = NULL;
        END CATCH

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

DECLARE @ServerFillFactor int = 0;

IF @IsAzureSqlDb = 0
BEGIN
    SELECT @ServerFillFactor = ISNULL(TRY_CONVERT(int, c.value_in_use), 0)
    FROM sys.configurations AS c
    WHERE c.name = 'fill factor (%)';
END

DECLARE @DbCount        int = (SELECT COUNT(*) FROM #DbScanned);
DECLARE @TotalIndexes   int = (SELECT COUNT(*) FROM #IndexOptions);
DECLARE @ExplicitFF     int = (SELECT COUNT(*) FROM #IndexOptions WHERE ISNULL(FillFactorValue, 0) <> 0);
DECLARE @LowFF          int = (SELECT COUNT(*) FROM #IndexOptions WHERE FillFactorValue BETWEEN 1 AND 49);
DECLARE @PageLocksOff   int = (SELECT COUNT(*) FROM #IndexOptions WHERE AllowPageLocks = 0);
DECLARE @RowLocksOff    int = (SELECT COUNT(*) FROM #IndexOptions WHERE AllowRowLocks = 0);
DECLARE @PaddedIndexes  int = (SELECT COUNT(*) FROM #IndexOptions WHERE IsPadded = 1);

DECLARE @DatabaseQueried nvarchar(max) =
    STUFF((SELECT N', ' + d.DatabaseName
           FROM #DbScanned AS d
           ORDER BY d.DatabaseName
           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

IF @DatabaseQueried IS NULL SET @DatabaseQueried = N'None';

DECLARE @LowFFList nvarchar(max) =
    STUFF((SELECT TOP (5) N'; ' + i.DatabaseName + N'.' + i.SchemaName + N'.' + i.TableName + N'.'
                        + ISNULL(i.IndexName, N'(unnamed)') + N' (FF=' + CONVERT(nvarchar(10), i.FillFactorValue) + N')'
           FROM #IndexOptions AS i
           WHERE i.FillFactorValue BETWEEN 1 AND 49
           ORDER BY i.FillFactorValue, i.DatabaseName, i.TableName
           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

DECLARE @LockList nvarchar(max) =
    STUFF((SELECT TOP (5) N'; ' + i.DatabaseName + N'.' + i.SchemaName + N'.' + i.TableName + N'.'
                        + ISNULL(i.IndexName, N'(unnamed)')
                        + N' (' + CASE WHEN i.AllowPageLocks = 0 THEN N'ALLOW_PAGE_LOCKS=OFF ' ELSE N'' END
                        + CASE WHEN i.AllowRowLocks = 0 THEN N'ALLOW_ROW_LOCKS=OFF' ELSE N'' END + N')'
           FROM #IndexOptions AS i
           WHERE i.AllowPageLocks = 0 OR i.AllowRowLocks = 0
           ORDER BY i.DatabaseName, i.TableName
           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

DECLARE @Score   int;
DECLARE @Result  nvarchar(20);
DECLARE @Finding nvarchar(max);

IF @DbCount = 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'No user database could be read, so index fill factor and storage options could not be assessed. Instance-level default fill factor (%) = '
                 + CONVERT(nvarchar(10), @ServerFillFactor) + N'.';
END
ELSE IF @TotalIndexes = 0 AND @ServerFillFactor = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'No user clustered or nonclustered indexes exist in the ' + CONVERT(nvarchar(10), @DbCount)
                 + N' database(s) scanned, and the instance-level default fill factor (%) is 0 (server default). There are no index storage options requiring deliberate configuration.';
END
ELSE IF @ExplicitFF > 0 AND @LowFF = 0 AND @PageLocksOff = 0 AND @RowLocksOff = 0 AND @ServerFillFactor = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'Fill factor is set deliberately: ' + CONVERT(nvarchar(10), @ExplicitFF) + N' of '
                 + CONVERT(nvarchar(10), @TotalIndexes) + N' user index(es) across ' + CONVERT(nvarchar(10), @DbCount)
                 + N' database(s) carry an explicit non-zero FILLFACTOR, none below 50. PAD_INDEX is enabled on '
                 + CONVERT(nvarchar(10), @PaddedIndexes) + N' index(es). No index has ALLOW_PAGE_LOCKS or ALLOW_ROW_LOCKS disabled, and the instance-level default fill factor (%) is 0, so per-index settings are not masked by a blanket server default.';
END
ELSE IF @ExplicitFF > 0 OR @ServerFillFactor <> 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'Index option configuration is only partially deliberate: ' + CONVERT(nvarchar(10), @ExplicitFF) + N' of '
                 + CONVERT(nvarchar(10), @TotalIndexes) + N' user index(es) across ' + CONVERT(nvarchar(10), @DbCount)
                 + N' database(s) have an explicit FILLFACTOR. Risk signals: instance-level default fill factor (%) = '
                 + CONVERT(nvarchar(10), @ServerFillFactor) + N'; ' + CONVERT(nvarchar(10), @LowFF)
                 + N' index(es) with FILLFACTOR below 50' + ISNULL(N' [' + @LowFFList + N']', N'') + N'; '
                 + CONVERT(nvarchar(10), @PageLocksOff) + N' index(es) with ALLOW_PAGE_LOCKS=OFF and '
                 + CONVERT(nvarchar(10), @RowLocksOff) + N' with ALLOW_ROW_LOCKS=OFF'
                 + ISNULL(N' [' + @LockList + N']', N'') + N'.';
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = N'No deliberate index storage configuration found: all ' + CONVERT(nvarchar(10), @TotalIndexes)
                 + N' user index(es) across ' + CONVERT(nvarchar(10), @DbCount)
                 + N' database(s) have fill_factor = 0 (never specified) and the instance-level default fill factor (%) is 0. '
                 + CONVERT(nvarchar(10), @PageLocksOff) + N' index(es) have ALLOW_PAGE_LOCKS=OFF and '
                 + CONVERT(nvarchar(10), @RowLocksOff) + N' have ALLOW_ROW_LOCKS=OFF'
                 + ISNULL(N' [' + @LockList + N']', N'')
                 + N'. FILLFACTOR and PAD_INDEX have not been considered for any index.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#IndexOptions') IS NOT NULL DROP TABLE #IndexOptions;
IF OBJECT_ID('tempdb..#DbScanned') IS NOT NULL DROP TABLE #DbScanned;