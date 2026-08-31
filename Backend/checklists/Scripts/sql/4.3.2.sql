SET NOCOUNT ON;

DECLARE @IsAzureSqlDb bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;
DECLARE @RowThreshold bigint = 1000000;

IF OBJECT_ID('tempdb..#DbList') IS NOT NULL DROP TABLE #DbList;
CREATE TABLE #DbList (DatabaseName sysname NOT NULL PRIMARY KEY);

IF OBJECT_ID('tempdb..#TableStats') IS NOT NULL DROP TABLE #TableStats;
CREATE TABLE #TableStats
(
    DatabaseName   sysname NOT NULL,
    SchemaName     sysname NOT NULL,
    TableName      sysname NOT NULL,
    TotalRows      bigint  NOT NULL,
    HasColumnstore bit     NOT NULL
);

IF @IsAzureSqlDb = 1
BEGIN
    INSERT INTO #DbList (DatabaseName)
    SELECT DB_NAME();

    INSERT INTO #TableStats (DatabaseName, SchemaName, TableName, TotalRows, HasColumnstore)
    SELECT
        DB_NAME(),
        s.name,
        t.name,
        ISNULL(rc.TotalRows, 0),
        CASE WHEN EXISTS (SELECT 1 FROM sys.indexes AS i
                          WHERE i.object_id = t.object_id AND i.type IN (5, 6))
             THEN 1 ELSE 0 END
    FROM sys.tables AS t
    INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    OUTER APPLY (
        SELECT SUM(p.rows) AS TotalRows
        FROM sys.partitions AS p
        WHERE p.object_id = t.object_id
          AND p.index_id IN (0, 1)
    ) AS rc
    WHERE t.is_ms_shipped = 0;
END
ELSE
BEGIN
    INSERT INTO #DbList (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.name NOT IN ('master', 'model', 'msdb', 'tempdb')
      AND d.state = 0
      AND d.is_read_only = 0
      AND d.source_database_id IS NULL
      AND HAS_DBACCESS(d.name) = 1;

    DECLARE @DbName sysname;
    DECLARE @Sql nvarchar(max);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT DatabaseName FROM #DbList ORDER BY DatabaseName;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'
            SELECT
                @db,
                s.name,
                t.name,
                ISNULL(rc.TotalRows, 0),
                CASE WHEN EXISTS (SELECT 1 FROM ' + QUOTENAME(@DbName) + N'.sys.indexes AS i
                                  WHERE i.object_id = t.object_id AND i.type IN (5, 6))
                     THEN 1 ELSE 0 END
            FROM ' + QUOTENAME(@DbName) + N'.sys.tables AS t
            INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas AS s ON s.schema_id = t.schema_id
            OUTER APPLY (
                SELECT SUM(p.rows) AS TotalRows
                FROM ' + QUOTENAME(@DbName) + N'.sys.partitions AS p
                WHERE p.object_id = t.object_id
                  AND p.index_id IN (0, 1)
            ) AS rc
            WHERE t.is_ms_shipped = 0;';

            INSERT INTO #TableStats (DatabaseName, SchemaName, TableName, TotalRows, HasColumnstore)
            EXEC sp_executesql @Sql, N'@db sysname', @db = @DbName;
        END TRY
        BEGIN CATCH
            /* Database unreadable for this login - skipped, remaining databases still evaluated. */
            SET @Sql = NULL;
        END CATCH

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

DECLARE @DbCount           int = (SELECT COUNT(*) FROM #DbList);
DECLARE @ScannedDbCount    int = (SELECT COUNT(DISTINCT DatabaseName) FROM #TableStats);
DECLARE @TableCount        int = (SELECT COUNT(*) FROM #TableStats);
DECLARE @LargeTables       int = (SELECT COUNT(*) FROM #TableStats WHERE TotalRows >= @RowThreshold);
DECLARE @LargeWithCs       int = (SELECT COUNT(*) FROM #TableStats WHERE TotalRows >= @RowThreshold AND HasColumnstore = 1);
DECLARE @AnyCsTables       int = (SELECT COUNT(*) FROM #TableStats WHERE HasColumnstore = 1);
DECLARE @Coverage decimal(5, 1) =
    CASE WHEN @LargeTables = 0 THEN 100.0
         ELSE CAST(@LargeWithCs * 100.0 / @LargeTables AS decimal(5, 1))
    END;

DECLARE @DatabasesQueried nvarchar(max) =
    ISNULL(STUFF((SELECT N', ' + DatabaseName
                  FROM #DbList
                  ORDER BY DatabaseName
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'None');

DECLARE @Uncovered nvarchar(max) =
    ISNULL(STUFF((SELECT TOP (5) N', ' + DatabaseName + N'.' + SchemaName + N'.' + TableName
                         + N' (' + CONVERT(nvarchar(30), TotalRows) + N' rows)'
                  FROM #TableStats
                  WHERE TotalRows >= @RowThreshold AND HasColumnstore = 0
                  ORDER BY TotalRows DESC
                  FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'none');

DECLARE @Result  nvarchar(20);
DECLARE @Score   int;
DECLARE @Finding nvarchar(max);

IF @DbCount = 0 OR @ScannedDbCount = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No accessible user database could be inspected (' + CONVERT(nvarchar(10), @DbCount)
                 + N' candidate database(s) enumerated, ' + CONVERT(nvarchar(10), @ScannedDbCount)
                 + N' readable). Columnstore index usage on large fact tables could not be determined; grant the audit login VIEW DEFINITION / VIEW DATABASE STATE and re-run.';
END
ELSE IF @LargeTables = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'No user table reaches the ' + CONVERT(nvarchar(30), @RowThreshold)
                 + N'-row large-table threshold across ' + CONVERT(nvarchar(10), @ScannedDbCount)
                 + N' database(s) (' + CONVERT(nvarchar(10), @TableCount)
                 + N' user tables inspected; ' + CONVERT(nvarchar(10), @AnyCsTables)
                 + N' table(s) already use a columnstore index). No fact-scale/analytical table warrants a columnstore index, so the control is satisfied by default.';
END
ELSE IF @LargeWithCs = @LargeTables
BEGIN
    SET @Score = 3;
    SET @Finding = N'All ' + CONVERT(nvarchar(10), @LargeTables) + N' large table(s) (>= '
                 + CONVERT(nvarchar(30), @RowThreshold) + N' rows) across ' + CONVERT(nvarchar(10), @ScannedDbCount)
                 + N' database(s) have a clustered or nonclustered columnstore index (100% coverage). '
                 + CONVERT(nvarchar(10), @AnyCsTables) + N' table(s) in total use columnstore indexes.';
END
ELSE IF @Coverage >= 50.0
BEGIN
    SET @Score = 2;
    SET @Finding = CONVERT(nvarchar(10), @LargeWithCs) + N' of ' + CONVERT(nvarchar(10), @LargeTables)
                 + N' large table(s) (>= ' + CONVERT(nvarchar(30), @RowThreshold) + N' rows) have a columnstore index ('
                 + CONVERT(nvarchar(10), @Coverage) + N'% coverage) across ' + CONVERT(nvarchar(10), @ScannedDbCount)
                 + N' database(s). Largest uncovered tables: ' + @Uncovered
                 + N'. Confirm whether the remaining tables are OLTP-only or genuinely analytical.';
END
ELSE IF @LargeWithCs > 0
BEGIN
    SET @Score = 1;
    SET @Finding = N'Only ' + CONVERT(nvarchar(10), @LargeWithCs) + N' of ' + CONVERT(nvarchar(10), @LargeTables)
                 + N' large table(s) (>= ' + CONVERT(nvarchar(30), @RowThreshold) + N' rows) have a columnstore index ('
                 + CONVERT(nvarchar(10), @Coverage) + N'% coverage) across ' + CONVERT(nvarchar(10), @ScannedDbCount)
                 + N' database(s). Largest uncovered tables: ' + @Uncovered + N'.';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = N'None of the ' + CONVERT(nvarchar(10), @LargeTables) + N' large table(s) (>= '
                 + CONVERT(nvarchar(30), @RowThreshold) + N' rows) across ' + CONVERT(nvarchar(10), @ScannedDbCount)
                 + N' database(s) have any clustered or nonclustered columnstore index (0% coverage). Largest uncovered tables: '
                 + @Uncovered + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result           AS Result,
    @Score            AS Score,
    @DatabasesQueried AS DatabaseQueried,
    @Finding          AS Finding;

IF OBJECT_ID('tempdb..#TableStats') IS NOT NULL DROP TABLE #TableStats;
IF OBJECT_ID('tempdb..#DbList') IS NOT NULL DROP TABLE #DbList;