/* Checklist 4.3.1 - Every table has an appropriate clustered index (or deliberate heap justification)
   Read-only: reads catalog views only and returns a single four-column result set. */
SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF OBJECT_ID('tempdb..#DbList') IS NOT NULL DROP TABLE #DbList;
CREATE TABLE #DbList
(
    DatabaseName SYSNAME NOT NULL PRIMARY KEY
);

IF OBJECT_ID('tempdb..#TableIndex') IS NOT NULL DROP TABLE #TableIndex;
CREATE TABLE #TableIndex
(
    DatabaseName SYSNAME NOT NULL,
    SchemaName   SYSNAME NOT NULL,
    TableName    SYSNAME NOT NULL,
    IsHeap       BIT     NOT NULL,
    ApproxRows   BIGINT  NOT NULL
);

/* Azure SQL Database (EngineEdition 5) does not support cross-database queries. */
IF @EngineEdition = 5
BEGIN
    INSERT INTO #DbList (DatabaseName)
    SELECT DB_NAME();
END
ELSE
BEGIN
    INSERT INTO #DbList (DatabaseName)
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4
      AND d.state = 0
      AND d.source_database_id IS NULL
      AND d.name NOT IN (N'SSISDB', N'ReportServer', N'ReportServerTempDB', N'distribution')
      AND HAS_DBACCESS(d.name) = 1;
END

DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Prefix NVARCHAR(300);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #DbList ORDER BY DatabaseName;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Prefix = CASE WHEN @EngineEdition = 5 THEN N'' ELSE QUOTENAME(@DbName) + N'.' END;

        SET @Sql = N'
SELECT @DbNameParam,
       s.name,
       t.name,
       CASE WHEN i.index_id = 0 THEN 1 ELSE 0 END,
       ISNULL(p.ApproxRows, 0)
FROM ' + @Prefix + N'sys.tables AS t
INNER JOIN ' + @Prefix + N'sys.schemas AS s
        ON s.schema_id = t.schema_id
INNER JOIN ' + @Prefix + N'sys.indexes AS i
        ON i.object_id = t.object_id
       AND i.index_id IN (0, 1)
OUTER APPLY (
    SELECT SUM(pt.rows) AS ApproxRows
    FROM ' + @Prefix + N'sys.partitions AS pt
    WHERE pt.object_id = t.object_id
      AND pt.index_id IN (0, 1)
) AS p
WHERE t.is_ms_shipped = 0
  AND s.name NOT IN (''sys'', ''INFORMATION_SCHEMA'');';

        INSERT INTO #TableIndex (DatabaseName, SchemaName, TableName, IsHeap, ApproxRows)
        EXEC sp_executesql @Sql, N'@DbNameParam SYSNAME', @DbNameParam = @DbName;
    END TRY
    BEGIN CATCH
        /* Database unreadable (offline, restoring, no permission) - skipped. */
        SET @Sql = NULL;
    END CATCH

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

DECLARE @DbCount        INT = 0;
DECLARE @TotalTables    INT = 0;
DECLARE @HeapCount      INT = 0;
DECLARE @HeapsWithRows  INT = 0;
DECLARE @HeapPct        DECIMAL(9, 2) = 0;

SELECT @DbCount = COUNT(*) FROM #DbList;

SELECT @TotalTables   = COUNT(*),
       @HeapCount     = SUM(CASE WHEN IsHeap = 1 THEN 1 ELSE 0 END),
       @HeapsWithRows = SUM(CASE WHEN IsHeap = 1 AND ApproxRows > 0 THEN 1 ELSE 0 END)
FROM #TableIndex;

SET @TotalTables   = ISNULL(@TotalTables, 0);
SET @HeapCount     = ISNULL(@HeapCount, 0);
SET @HeapsWithRows = ISNULL(@HeapsWithRows, 0);
SET @HeapPct       = CASE WHEN @TotalTables = 0 THEN 0
                          ELSE CAST(@HeapCount AS DECIMAL(9, 2)) * 100.0 / @TotalTables
                     END;

DECLARE @DbQueried NVARCHAR(MAX);
SET @DbQueried = STUFF((SELECT N', ' + DatabaseName
                        FROM #DbList
                        ORDER BY DatabaseName
                        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');
SET @DbQueried = ISNULL(@DbQueried, N'None');

DECLARE @TopHeaps NVARCHAR(MAX);
SET @TopHeaps = STUFF((SELECT TOP (5) N'; ' + DatabaseName + N'.' + SchemaName + N'.' + TableName
                              + N' (' + CAST(ApproxRows AS NVARCHAR(20)) + N' rows)'
                       FROM #TableIndex
                       WHERE IsHeap = 1
                       ORDER BY ApproxRows DESC
                       FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

DECLARE @Result  NVARCHAR(50);
DECLARE @Score   INT;
DECLARE @Finding NVARCHAR(MAX);

IF @DbCount = 0
BEGIN
    SET @Score   = 0;
    SET @Finding = N'No accessible online user database was found on this instance, so clustered index coverage could not be assessed.';
END
ELSE IF @TotalTables = 0
BEGIN
    SET @Score   = 0;
    SET @Finding = N'No user tables were readable in the ' + CAST(@DbCount AS NVARCHAR(10))
                 + N' accessible user database(s) (' + @DbQueried + N'), so clustered index coverage could not be assessed.';
END
ELSE IF @HeapCount = 0
BEGIN
    SET @Score   = 3;
    SET @Finding = N'All ' + CAST(@TotalTables AS NVARCHAR(10)) + N' user table(s) across '
                 + CAST(@DbCount AS NVARCHAR(10)) + N' database(s) have a clustered index; 0 heaps detected.';
END
ELSE IF @HeapPct <= 10.00
BEGIN
    SET @Score   = 2;
    SET @Finding = CAST(@HeapCount AS NVARCHAR(10)) + N' of ' + CAST(@TotalTables AS NVARCHAR(10))
                 + N' user table(s) (' + CAST(@HeapPct AS NVARCHAR(20)) + N'%) across '
                 + CAST(@DbCount AS NVARCHAR(10)) + N' database(s) are heaps, of which '
                 + CAST(@HeapsWithRows AS NVARCHAR(10)) + N' contain rows. Largest heaps: '
                 + ISNULL(@TopHeaps, N'n/a') + N'.';
END
ELSE
BEGIN
    SET @Score   = 1;
    SET @Finding = CAST(@HeapCount AS NVARCHAR(10)) + N' of ' + CAST(@TotalTables AS NVARCHAR(10))
                 + N' user table(s) (' + CAST(@HeapPct AS NVARCHAR(20)) + N'%) across '
                 + CAST(@DbCount AS NVARCHAR(10)) + N' database(s) are heaps, of which '
                 + CAST(@HeapsWithRows AS NVARCHAR(10)) + N' contain rows. Largest heaps: '
                 + ISNULL(@TopHeaps, N'n/a') + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result    AS Result,
       @Score     AS Score,
       @DbQueried AS DatabaseQueried,
       @Finding   AS Finding;