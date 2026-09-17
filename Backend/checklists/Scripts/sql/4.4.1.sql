/*
    Checklist Item : 4.4.1 - Partitioning strategy defined for large tables (by date/range) where beneficial
    Scope          : DATABASE (all accessible online user databases; current database only on Azure SQL Database)
    Type           : Read-only. Queries catalog views only. No data or configuration is modified.
    Output         : Result, Score, DatabaseQueried, Finding
*/
SET NOCOUNT ON;

DECLARE @EngineEdition   INT           = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Threshold       BIGINT        = 1000000;   -- rows at/above which partitioning is considered beneficial
DECLARE @Result          NVARCHAR(20);
DECLARE @Score           INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding         NVARCHAR(MAX);

IF OBJECT_ID('tempdb..#LargeTables') IS NOT NULL DROP TABLE #LargeTables;
CREATE TABLE #LargeTables
(
    DatabaseName        SYSNAME        NOT NULL,
    TableName           NVARCHAR(512)  NOT NULL,
    TotalRows           BIGINT         NULL,
    IsPartitioned       BIT            NOT NULL,
    PartitionCount      INT            NULL,
    PartitionColumnType SYSNAME        NULL
);

IF OBJECT_ID('tempdb..#Scanned') IS NOT NULL DROP TABLE #Scanned;
CREATE TABLE #Scanned
(
    DatabaseName SYSNAME       NOT NULL,
    ScanStatus   NVARCHAR(200) NOT NULL
);

IF @EngineEdition = 5   -- Azure SQL Database: cross-database queries are not supported
BEGIN
    INSERT INTO #Scanned (DatabaseName, ScanStatus) VALUES (DB_NAME(), N'Scanned');

    INSERT INTO #LargeTables (DatabaseName, TableName, TotalRows, IsPartitioned, PartitionCount, PartitionColumnType)
    SELECT DB_NAME(),
           QUOTENAME(s.name) + N'.' + QUOTENAME(t.name),
           x.TotalRows,
           CASE WHEN ps.data_space_id IS NOT NULL THEN 1 ELSE 0 END,
           x.PartCount,
           pc.PartitionColumnType
    FROM sys.tables AS t
    INNER JOIN sys.schemas AS s
        ON s.schema_id = t.schema_id
    INNER JOIN sys.indexes AS i
        ON i.object_id = t.object_id
       AND i.index_id IN (0, 1)
    LEFT JOIN sys.partition_schemes AS ps
        ON ps.data_space_id = i.data_space_id
    CROSS APPLY (
        SELECT SUM(p.rows), COUNT(*)
        FROM sys.partitions AS p
        WHERE p.object_id = t.object_id
          AND p.index_id  = i.index_id
    ) AS x (TotalRows, PartCount)
    OUTER APPLY (
        SELECT TOP (1) ty.name
        FROM sys.index_columns AS ic
        INNER JOIN sys.columns AS c
            ON c.object_id = ic.object_id
           AND c.column_id = ic.column_id
        INNER JOIN sys.types AS ty
            ON ty.user_type_id = c.user_type_id
        WHERE ic.object_id        = i.object_id
          AND ic.index_id         = i.index_id
          AND ic.partition_ordinal = 1
    ) AS pc (PartitionColumnType)
    WHERE t.is_ms_shipped = 0
      AND x.TotalRows >= @Threshold;
END
ELSE
BEGIN
    DECLARE @DbName SYSNAME;
    DECLARE @Sql    NVARCHAR(MAX);

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0                    -- ONLINE
          AND d.source_database_id IS NULL   -- exclude database snapshots
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'
            SELECT @DbNameParam,
                   QUOTENAME(s.name) + N''.'' + QUOTENAME(t.name),
                   x.TotalRows,
                   CASE WHEN ps.data_space_id IS NOT NULL THEN 1 ELSE 0 END,
                   x.PartCount,
                   pc.PartitionColumnType
            FROM ' + QUOTENAME(@DbName) + N'.sys.tables AS t
            INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.schemas AS s
                ON s.schema_id = t.schema_id
            INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.indexes AS i
                ON i.object_id = t.object_id
               AND i.index_id IN (0, 1)
            LEFT JOIN ' + QUOTENAME(@DbName) + N'.sys.partition_schemes AS ps
                ON ps.data_space_id = i.data_space_id
            CROSS APPLY (
                SELECT SUM(p.rows), COUNT(*)
                FROM ' + QUOTENAME(@DbName) + N'.sys.partitions AS p
                WHERE p.object_id = t.object_id
                  AND p.index_id  = i.index_id
            ) AS x (TotalRows, PartCount)
            OUTER APPLY (
                SELECT TOP (1) ty.name
                FROM ' + QUOTENAME(@DbName) + N'.sys.index_columns AS ic
                INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.columns AS c
                    ON c.object_id = ic.object_id
                   AND c.column_id = ic.column_id
                INNER JOIN ' + QUOTENAME(@DbName) + N'.sys.types AS ty
                    ON ty.user_type_id = c.user_type_id
                WHERE ic.object_id        = i.object_id
                  AND ic.index_id         = i.index_id
                  AND ic.partition_ordinal = 1
            ) AS pc (PartitionColumnType)
            WHERE t.is_ms_shipped = 0
              AND x.TotalRows >= @ThresholdParam;';

            INSERT INTO #LargeTables (DatabaseName, TableName, TotalRows, IsPartitioned, PartitionCount, PartitionColumnType)
            EXEC sp_executesql @Sql,
                 N'@DbNameParam SYSNAME, @ThresholdParam BIGINT',
                 @DbNameParam = @DbName,
                 @ThresholdParam = @Threshold;

            INSERT INTO #Scanned (DatabaseName, ScanStatus) VALUES (@DbName, N'Scanned');
        END TRY
        BEGIN CATCH
            INSERT INTO #Scanned (DatabaseName, ScanStatus)
            VALUES (@DbName, N'Not scanned: ' + LEFT(ERROR_MESSAGE(), 150));
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

DECLARE @DbCount        INT = (SELECT COUNT(*) FROM #Scanned WHERE ScanStatus = N'Scanned');
DECLARE @DbFailed       INT = (SELECT COUNT(*) FROM #Scanned WHERE ScanStatus <> N'Scanned');
DECLARE @LargeCount     INT = (SELECT COUNT(*) FROM #LargeTables);
DECLARE @PartCount      INT = (SELECT COUNT(*) FROM #LargeTables WHERE IsPartitioned = 1);
DECLARE @RangeKeyCount  INT = (SELECT COUNT(*) FROM #LargeTables
                               WHERE IsPartitioned = 1
                                 AND PartitionColumnType IN (N'date', N'datetime', N'datetime2', N'smalldatetime',
                                                             N'datetimeoffset', N'int', N'bigint', N'smallint'));

SET @DatabaseQueried = ISNULL(STUFF((SELECT N', ' + DatabaseName
                                     FROM #Scanned
                                     ORDER BY DatabaseName
                                     FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''),
                              N'None');

DECLARE @UnpartitionedList NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT TOP (5) N'; ' + DatabaseName + N'.' + TableName + N' (' + CAST(ISNULL(TotalRows, 0) AS NVARCHAR(20)) + N' rows)'
                  FROM #LargeTables
                  WHERE IsPartitioned = 0
                  ORDER BY TotalRows DESC
                  FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'none');

DECLARE @PartitionedList NVARCHAR(MAX) =
    ISNULL(STUFF((SELECT TOP (5) N'; ' + DatabaseName + N'.' + TableName + N' (' + CAST(ISNULL(PartitionCount, 0) AS NVARCHAR(20))
                         + N' partitions, key type ' + ISNULL(PartitionColumnType, N'unknown') + N')'
                  FROM #LargeTables
                  WHERE IsPartitioned = 1
                  ORDER BY TotalRows DESC
                  FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'none');

IF @LargeCount = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'No user table at or above ' + CAST(@Threshold AS NVARCHAR(20)) + N' rows was found in the '
                 + CAST(@DbCount AS NVARCHAR(10)) + N' database(s) scanned, so table partitioning is not currently beneficial.';
END
ELSE IF @PartCount = @LargeCount AND @RangeKeyCount = @LargeCount
BEGIN
    SET @Score = 3;
    SET @Finding = N'All ' + CAST(@LargeCount AS NVARCHAR(10)) + N' large table(s) (>= ' + CAST(@Threshold AS NVARCHAR(20))
                 + N' rows) across ' + CAST(@DbCount AS NVARCHAR(10)) + N' database(s) are partitioned on a date/numeric range key. Examples: '
                 + @PartitionedList + N'.';
END
ELSE IF @PartCount = @LargeCount
BEGIN
    SET @Score = 2;
    SET @Finding = N'All ' + CAST(@LargeCount AS NVARCHAR(10)) + N' large table(s) are partitioned, but only '
                 + CAST(@RangeKeyCount AS NVARCHAR(10)) + N' use a date or numeric range partitioning key. Partitioned tables: '
                 + @PartitionedList + N'.';
END
ELSE IF @PartCount > 0
BEGIN
    SET @Score = 2;
    SET @Finding = CAST(@PartCount AS NVARCHAR(10)) + N' of ' + CAST(@LargeCount AS NVARCHAR(10)) + N' large table(s) (>= '
                 + CAST(@Threshold AS NVARCHAR(20)) + N' rows) are partitioned. Largest unpartitioned tables: ' + @UnpartitionedList + N'.';
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = N'None of the ' + CAST(@LargeCount AS NVARCHAR(10)) + N' large table(s) (>= ' + CAST(@Threshold AS NVARCHAR(20))
                 + N' rows) found across ' + CAST(@DbCount AS NVARCHAR(10))
                 + N' database(s) use table partitioning. Largest unpartitioned tables: ' + @UnpartitionedList + N'.';
END

IF @DbFailed > 0
    SET @Finding = @Finding + N' Note: ' + CAST(@DbFailed AS NVARCHAR(10)) + N' database(s) could not be inspected (access denied or unavailable).';

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;

DROP TABLE #LargeTables;
DROP TABLE #Scanned;