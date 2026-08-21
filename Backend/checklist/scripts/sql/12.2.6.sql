SET NOCOUNT ON;

DECLARE @IsAzureDb bit = CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @RowThreshold bigint = 100000;

CREATE TABLE #CompressionUsage
(
    DatabaseName      sysname,
    LargeObjects      int,
    CompressedObjects int
);

IF @IsAzureDb = 1
BEGIN
    INSERT INTO #CompressionUsage (DatabaseName, LargeObjects, CompressedObjects)
    SELECT DB_NAME(),
           COUNT(*),
           ISNULL(SUM(CASE WHEN p.data_compression > 0 THEN 1 ELSE 0 END), 0)
    FROM sys.partitions AS p
    INNER JOIN sys.objects AS o ON p.object_id = o.object_id
    WHERE o.is_ms_shipped = 0
      AND o.type = 'U'
      AND p.rows >= @RowThreshold;
END
ELSE
BEGIN
    DECLARE @DbName sysname;
    DECLARE @Sql nvarchar(max);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.source_database_id IS NULL
          AND d.is_in_standby = 0
          AND HAS_DBACCESS(d.name) = 1;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Sql = N'SELECT @Db, COUNT(*), ISNULL(SUM(CASE WHEN p.data_compression > 0 THEN 1 ELSE 0 END), 0) '
                 + N'FROM ' + QUOTENAME(@DbName) + N'.sys.partitions AS p '
                 + N'INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.objects AS o ON p.object_id = o.object_id '
                 + N'WHERE o.is_ms_shipped = 0 AND o.type = ''U'' AND p.rows >= @Threshold;';

        BEGIN TRY
            INSERT INTO #CompressionUsage (DatabaseName, LargeObjects, CompressedObjects)
            EXEC sp_executesql @Sql,
                 N'@Db sysname, @Threshold bigint',
                 @Db = @DbName,
                 @Threshold = @RowThreshold;
        END TRY
        BEGIN CATCH
            -- database not readable by this login; skip it
        END CATCH

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

DECLARE @BackupCompression int = NULL;

IF @IsAzureDb = 0
BEGIN
    SELECT @BackupCompression = CONVERT(int, c.value_in_use)
    FROM sys.configurations AS c
    WHERE c.name = 'backup compression default';
END

DECLARE @DbCount         int = (SELECT COUNT(*) FROM #CompressionUsage);
DECLARE @TotalLarge      int = ISNULL((SELECT SUM(LargeObjects) FROM #CompressionUsage), 0);
DECLARE @TotalCompressed int = ISNULL((SELECT SUM(CompressedObjects) FROM #CompressionUsage), 0);
DECLARE @Pct             int = CASE WHEN @TotalLarge = 0 THEN 0
                                    ELSE CONVERT(int, (@TotalCompressed * 100.0) / @TotalLarge) END;

DECLARE @DatabaseQueried nvarchar(max) =
    STUFF((SELECT N', ' + u.DatabaseName
           FROM #CompressionUsage AS u
           ORDER BY u.DatabaseName
           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

IF @DatabaseQueried IS NULL SET @DatabaseQueried = N'None';
IF LEN(@DatabaseQueried) > 200
    SET @DatabaseQueried = LEFT(@DatabaseQueried, 200) + N'... (' + CONVERT(nvarchar(10), @DbCount) + N' databases)';

DECLARE @BackupText nvarchar(200) =
    CASE WHEN @IsAzureDb = 1 THEN N'Backup compression default: not applicable (Azure SQL Database).'
         WHEN @BackupCompression = 1 THEN N'Backup compression default: ENABLED.'
         WHEN @BackupCompression = 0 THEN N'Backup compression default: DISABLED.'
         ELSE N'Backup compression default: could not be read.' END;

DECLARE @Score int;
DECLARE @Result nvarchar(20);
DECLARE @Finding nvarchar(max);

IF @TotalLarge = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'No user table partitions with at least '
                 + CONVERT(nvarchar(20), @RowThreshold) + N' rows were found across '
                 + CONVERT(nvarchar(10), @DbCount) + N' accessible user database(s), so data compression offers no material storage or I/O saving at current data volumes. '
                 + @BackupText;
END
ELSE IF @Pct >= 75 AND (@IsAzureDb = 1 OR @BackupCompression = 1)
BEGIN
    SET @Score = 3;
    SET @Finding = CONVERT(nvarchar(10), @TotalCompressed) + N' of ' + CONVERT(nvarchar(10), @TotalLarge)
                 + N' large partitions (' + CONVERT(nvarchar(10), @Pct) + N'%) across '
                 + CONVERT(nvarchar(10), @DbCount) + N' user database(s) use ROW, PAGE or columnstore compression. '
                 + @BackupText;
END
ELSE IF @Pct >= 25 OR @BackupCompression = 1
BEGIN
    SET @Score = 2;
    SET @Finding = N'Compression is only partially adopted: ' + CONVERT(nvarchar(10), @TotalCompressed) + N' of '
                 + CONVERT(nvarchar(10), @TotalLarge) + N' large partitions ('
                 + CONVERT(nvarchar(10), @Pct) + N'%) across ' + CONVERT(nvarchar(10), @DbCount)
                 + N' user database(s) are compressed. ' + @BackupText;
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = N'Compression is effectively unused: only ' + CONVERT(nvarchar(10), @TotalCompressed) + N' of '
                 + CONVERT(nvarchar(10), @TotalLarge) + N' large partitions ('
                 + CONVERT(nvarchar(10), @Pct) + N'%) across ' + CONVERT(nvarchar(10), @DbCount)
                 + N' user database(s) are compressed. ' + @BackupText;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;

DROP TABLE #CompressionUsage;