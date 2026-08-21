SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#CompressionScan') IS NOT NULL
    DROP TABLE #CompressionScan;

CREATE TABLE #CompressionScan
(
    DatabaseName         sysname        NOT NULL,
    LargePartitions      bigint         NULL,
    LargeCompressed      bigint         NULL,
    ColumnstoreIndexes   bigint         NULL,
    AnyCompressed        bigint         NULL,
    ErrorMessage         nvarchar(2000) NULL
);

DECLARE @EngineEdition int = CAST(SERVERPROPERTY('EngineEdition') AS int);
DECLARE @LargeRowThreshold bigint = 100000;
DECLARE @db sysname;
DECLARE @sql nvarchar(max);

IF @EngineEdition = 5
BEGIN
    /* Azure SQL Database: cross-database catalog access is not permitted, so only the current database is visible. */
    INSERT INTO #CompressionScan (DatabaseName, LargePartitions, LargeCompressed, ColumnstoreIndexes, AnyCompressed)
    SELECT
        DB_NAME(),
        (SELECT COUNT_BIG(*)
           FROM sys.partitions AS p
           INNER JOIN sys.objects AS o ON o.object_id = p.object_id
          WHERE o.type = 'U' AND o.is_ms_shipped = 0 AND p.[rows] >= @LargeRowThreshold),
        (SELECT COUNT_BIG(*)
           FROM sys.partitions AS p
           INNER JOIN sys.objects AS o ON o.object_id = p.object_id
          WHERE o.type = 'U' AND o.is_ms_shipped = 0 AND p.[rows] >= @LargeRowThreshold AND p.data_compression > 0),
        (SELECT COUNT_BIG(*)
           FROM sys.indexes AS i
           INNER JOIN sys.objects AS o ON o.object_id = i.object_id
          WHERE o.type = 'U' AND o.is_ms_shipped = 0 AND i.type IN (5, 6)),
        (SELECT COUNT_BIG(*)
           FROM sys.partitions AS p
           INNER JOIN sys.objects AS o ON o.object_id = p.object_id
          WHERE o.type = 'U' AND o.is_ms_shipped = 0 AND p.data_compression > 0);
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
          FROM sys.databases AS d
         WHERE d.database_id > 4
           AND d.state = 0
           AND d.source_database_id IS NULL
           AND d.is_in_standby = 0
           AND HAS_DBACCESS(d.name) = 1
         ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @sql = N'
            SELECT
                @dbname,
                (SELECT COUNT_BIG(*)
                   FROM ' + QUOTENAME(@db) + N'.sys.partitions AS p
                   INNER JOIN ' + QUOTENAME(@db) + N'.sys.objects AS o ON o.object_id = p.object_id
                  WHERE o.type = ''U'' AND o.is_ms_shipped = 0 AND p.[rows] >= @threshold),
                (SELECT COUNT_BIG(*)
                   FROM ' + QUOTENAME(@db) + N'.sys.partitions AS p
                   INNER JOIN ' + QUOTENAME(@db) + N'.sys.objects AS o ON o.object_id = p.object_id
                  WHERE o.type = ''U'' AND o.is_ms_shipped = 0 AND p.[rows] >= @threshold AND p.data_compression > 0),
                (SELECT COUNT_BIG(*)
                   FROM ' + QUOTENAME(@db) + N'.sys.indexes AS i
                   INNER JOIN ' + QUOTENAME(@db) + N'.sys.objects AS o ON o.object_id = i.object_id
                  WHERE o.type = ''U'' AND o.is_ms_shipped = 0 AND i.type IN (5, 6)),
                (SELECT COUNT_BIG(*)
                   FROM ' + QUOTENAME(@db) + N'.sys.partitions AS p
                   INNER JOIN ' + QUOTENAME(@db) + N'.sys.objects AS o ON o.object_id = p.object_id
                  WHERE o.type = ''U'' AND o.is_ms_shipped = 0 AND p.data_compression > 0);';

            INSERT INTO #CompressionScan (DatabaseName, LargePartitions, LargeCompressed, ColumnstoreIndexes, AnyCompressed)
            EXEC sp_executesql @sql,
                 N'@dbname sysname, @threshold bigint',
                 @dbname = @db,
                 @threshold = @LargeRowThreshold;
        END TRY
        BEGIN CATCH
            INSERT INTO #CompressionScan (DatabaseName, ErrorMessage)
            VALUES (@db, LEFT(ERROR_MESSAGE(), 2000));
        END CATCH

        FETCH NEXT FROM db_cursor INTO @db;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

DECLARE @DbInspected      int    = (SELECT COUNT(*) FROM #CompressionScan WHERE ErrorMessage IS NULL);
DECLARE @DbFailed         int    = (SELECT COUNT(*) FROM #CompressionScan WHERE ErrorMessage IS NOT NULL);
DECLARE @LargeTotal       bigint = ISNULL((SELECT SUM(LargePartitions)    FROM #CompressionScan), 0);
DECLARE @LargeCompressed  bigint = ISNULL((SELECT SUM(LargeCompressed)    FROM #CompressionScan), 0);
DECLARE @Columnstore      bigint = ISNULL((SELECT SUM(ColumnstoreIndexes) FROM #CompressionScan), 0);
DECLARE @AnyCompressed    bigint = ISNULL((SELECT SUM(AnyCompressed)      FROM #CompressionScan), 0);

DECLARE @Coverage decimal(5,2) =
    CASE WHEN @LargeTotal > 0
         THEN CAST((@LargeCompressed * 100.0) / @LargeTotal AS decimal(5,2))
         ELSE NULL
    END;

DECLARE @DatabaseQueried nvarchar(max) =
    STUFF((SELECT N', ' + s.DatabaseName
             FROM #CompressionScan AS s
            WHERE s.ErrorMessage IS NULL
            ORDER BY s.DatabaseName
              FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

DECLARE @TopUncompressed nvarchar(max) =
    STUFF((SELECT TOP (5) N', ' + s.DatabaseName + N' (' +
                  CAST(s.LargePartitions - s.LargeCompressed AS nvarchar(20)) + N')'
             FROM #CompressionScan AS s
            WHERE s.ErrorMessage IS NULL
              AND ISNULL(s.LargePartitions, 0) - ISNULL(s.LargeCompressed, 0) > 0
            ORDER BY (s.LargePartitions - s.LargeCompressed) DESC
              FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

DECLARE @Result  nvarchar(50);
DECLARE @Score   int;
DECLARE @Finding nvarchar(max);

IF @DbInspected = 0 OR @DatabaseQueried IS NULL OR LEN(@DatabaseQueried) = 0
BEGIN
    SET @DatabaseQueried = N'None';
    SET @Score = 0;
    SET @Finding = N'No database found to be queried';
END
ELSE
BEGIN
    IF @LargeTotal = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = N'Across ' + CAST(@DbInspected AS nvarchar(20)) + N' user database(s), no user table partition reaches '
                     + CAST(@LargeRowThreshold AS nvarchar(20)) + N' rows, so no object is large enough to benefit materially from data compression. '
                     + CAST(@AnyCompressed AS nvarchar(20)) + N' partition(s) are already compressed and '
                     + CAST(@Columnstore AS nvarchar(20)) + N' columnstore index(es) exist.';
    END
    ELSE IF @Coverage >= 50.00
    BEGIN
        SET @Score = 3;
        SET @Finding = N'Data compression is applied where beneficial: ' + CAST(@LargeCompressed AS nvarchar(20)) + N' of '
                     + CAST(@LargeTotal AS nvarchar(20)) + N' large partitions (>= ' + CAST(@LargeRowThreshold AS nvarchar(20))
                     + N' rows) use ROW, PAGE or COLUMNSTORE compression (' + CAST(@Coverage AS nvarchar(20)) + N'%) across '
                     + CAST(@DbInspected AS nvarchar(20)) + N' user database(s). '
                     + CAST(@Columnstore AS nvarchar(20)) + N' columnstore index(es) and '
                     + CAST(@AnyCompressed AS nvarchar(20)) + N' compressed partition(s) in total were found.'
                     + CASE WHEN @TopUncompressed IS NOT NULL
                            THEN N' Remaining uncompressed large partitions by database: ' + @TopUncompressed + N'.'
                            ELSE N'' END;
    END
    ELSE IF @Coverage > 0.00
    BEGIN
        SET @Score = 2;
        SET @Finding = N'Data compression is applied only sparsely: ' + CAST(@LargeCompressed AS nvarchar(20)) + N' of '
                     + CAST(@LargeTotal AS nvarchar(20)) + N' large partitions (>= ' + CAST(@LargeRowThreshold AS nvarchar(20))
                     + N' rows) are compressed (' + CAST(@Coverage AS nvarchar(20)) + N'%) across '
                     + CAST(@DbInspected AS nvarchar(20)) + N' user database(s), leaving '
                     + CAST(@LargeTotal - @LargeCompressed AS nvarchar(20)) + N' large partition(s) uncompressed.'
                     + CASE WHEN @TopUncompressed IS NOT NULL
                            THEN N' Largest gaps by database: ' + @TopUncompressed + N'.'
                            ELSE N'' END;
    END
    ELSE IF @AnyCompressed > 0 OR @Columnstore > 0
    BEGIN
        SET @Score = 2;
        SET @Finding = N'None of the ' + CAST(@LargeTotal AS nvarchar(20)) + N' large partitions (>= '
                     + CAST(@LargeRowThreshold AS nvarchar(20)) + N' rows) is compressed, although compression is in use elsewhere ('
                     + CAST(@AnyCompressed AS nvarchar(20)) + N' compressed partition(s) on smaller objects and '
                     + CAST(@Columnstore AS nvarchar(20)) + N' columnstore index(es)) across '
                     + CAST(@DbInspected AS nvarchar(20)) + N' user database(s). Compression is therefore not being applied where it is most beneficial.'
                     + CASE WHEN @TopUncompressed IS NOT NULL
                            THEN N' Largest gaps by database: ' + @TopUncompressed + N'.'
                            ELSE N'' END;
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Finding = N'No data compression of any kind is applied: 0 of ' + CAST(@LargeTotal AS nvarchar(20))
                     + N' large partitions (>= ' + CAST(@LargeRowThreshold AS nvarchar(20)) + N' rows) use ROW or PAGE compression, '
                     + N'no columnstore index exists, and no partition in any of the '
                     + CAST(@DbInspected AS nvarchar(20)) + N' inspected user database(s) is compressed.'
                     + CASE WHEN @TopUncompressed IS NOT NULL
                            THEN N' Largest gaps by database: ' + @TopUncompressed + N'.'
                            ELSE N'' END;
    END

    IF @DbFailed > 0
        SET @Finding = @Finding + N' Note: ' + CAST(@DbFailed AS nvarchar(20))
                     + N' database(s) could not be read and were excluded from the calculation.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#CompressionScan') IS NOT NULL
    DROP TABLE #CompressionScan;