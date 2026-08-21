/* Checklist 4.4.2 - Partition alignment supports fast load/switch and purge (sliding window). Read-only. */
SET NOCOUNT ON;

IF OBJECT_ID(N'tempdb..#DbList') IS NOT NULL DROP TABLE #DbList;
CREATE TABLE #DbList (DatabaseName sysname NOT NULL PRIMARY KEY);

IF OBJECT_ID(N'tempdb..#PartitionAudit') IS NOT NULL DROP TABLE #PartitionAudit;
CREATE TABLE #PartitionAudit
(
    DatabaseName        sysname NOT NULL,
    PartitionedTables   int     NOT NULL,
    MisalignedIndexes   int     NOT NULL,
    TablesMisaligned    int     NOT NULL,
    SlidingWindowReady  int     NOT NULL,
    LargeUnpartitioned  int     NOT NULL
);

DECLARE @EngineEdition int = CAST(SERVERPROPERTY(N'EngineEdition') AS int);

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
      AND d.state_desc = N'ONLINE'
      AND d.is_read_only = 0
      AND d.source_database_id IS NULL
      AND d.name NOT IN (N'distribution', N'SSISDB', N'ReportServer', N'ReportServerTempDB')
      AND HAS_DBACCESS(d.name) = 1
      AND DATABASEPROPERTYEX(d.name, N'Updateability') = N'READ_WRITE';
END

DECLARE @DbName    sysname,
        @Exec      nvarchar(300),
        @Sql       nvarchar(max),
        @FailedDbs int = 0;

SET @Sql = N'
WITH PT AS (
    SELECT t.object_id AS ObjectId, i.data_space_id AS SchemeId
    FROM sys.tables AS t
    INNER JOIN sys.indexes AS i
        ON i.object_id = t.object_id AND i.index_id IN (0, 1)
    INNER JOIN sys.partition_schemes AS ps
        ON ps.data_space_id = i.data_space_id
    WHERE t.is_ms_shipped = 0
),
MIS AS (
    SELECT i.object_id AS ObjectId, i.index_id AS IndexId
    FROM sys.indexes AS i
    INNER JOIN PT ON PT.ObjectId = i.object_id
    WHERE i.index_id > 1
      AND i.type IN (2, 6)
      AND ISNULL(i.data_space_id, 0) <> PT.SchemeId
),
PROWS AS (
    SELECT p.object_id AS ObjectId, p.partition_number AS PartitionNumber, SUM(p.rows) AS RowsInPartition
    FROM sys.partitions AS p
    INNER JOIN PT ON PT.ObjectId = p.object_id
    WHERE p.index_id IN (0, 1)
    GROUP BY p.object_id, p.partition_number
),
PMAX AS (
    SELECT ObjectId, MAX(PartitionNumber) AS MaxPart
    FROM PROWS
    GROUP BY ObjectId
),
BOUND AS (
    SELECT r.ObjectId,
           MAX(m.MaxPart) AS MaxPart,
           MAX(CASE WHEN r.PartitionNumber = 1 AND r.RowsInPartition = 0 THEN 1 ELSE 0 END) AS FirstEmpty,
           MAX(CASE WHEN r.PartitionNumber = m.MaxPart AND r.RowsInPartition = 0 THEN 1 ELSE 0 END) AS LastEmpty
    FROM PROWS AS r
    INNER JOIN PMAX AS m ON m.ObjectId = r.ObjectId
    GROUP BY r.ObjectId
),
BIG AS (
    SELECT t.object_id AS ObjectId
    FROM sys.tables AS t
    INNER JOIN sys.indexes AS i
        ON i.object_id = t.object_id AND i.index_id IN (0, 1)
    INNER JOIN sys.partitions AS p
        ON p.object_id = i.object_id AND p.index_id = i.index_id
    WHERE t.is_ms_shipped = 0
      AND NOT EXISTS (SELECT 1 FROM sys.partition_schemes AS ps2 WHERE ps2.data_space_id = i.data_space_id)
    GROUP BY t.object_id
    HAVING SUM(p.rows) >= 50000000
)
SELECT DB_NAME(),
       (SELECT COUNT(*) FROM PT),
       (SELECT COUNT(*) FROM MIS),
       (SELECT COUNT(DISTINCT ObjectId) FROM MIS),
       (SELECT COUNT(*) FROM BOUND WHERE MaxPart > 1 AND (FirstEmpty = 1 OR LastEmpty = 1)),
       (SELECT COUNT(*) FROM BIG);';

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM #DbList ORDER BY DatabaseName;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Exec = CASE WHEN @EngineEdition = 5
                         THEN N'sys.sp_executesql'
                         ELSE QUOTENAME(@DbName) + N'.sys.sp_executesql'
                    END;

        INSERT INTO #PartitionAudit
            (DatabaseName, PartitionedTables, MisalignedIndexes, TablesMisaligned, SlidingWindowReady, LargeUnpartitioned)
        EXEC @Exec @Sql;
    END TRY
    BEGIN CATCH
        SET @FailedDbs = @FailedDbs + 1;
    END CATCH

    FETCH NEXT FROM db_cur INTO @DbName;
END

CLOSE db_cur;
DEALLOCATE db_cur;

DECLARE @DbCount     int,
        @PartTables  int,
        @MisIdx      int,
        @MisTables   int,
        @Sliding     int,
        @LargeUnpart int;

SELECT @DbCount = COUNT(*) FROM #DbList;

SELECT @PartTables  = ISNULL(SUM(PartitionedTables), 0),
       @MisIdx      = ISNULL(SUM(MisalignedIndexes), 0),
       @MisTables   = ISNULL(SUM(TablesMisaligned), 0),
       @Sliding     = ISNULL(SUM(SlidingWindowReady), 0),
       @LargeUnpart = ISNULL(SUM(LargeUnpartitioned), 0)
FROM #PartitionAudit;

DECLARE @DatabaseQueried nvarchar(max) =
    STUFF((SELECT N', ' + DatabaseName
           FROM #DbList
           ORDER BY DatabaseName
           FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'');

IF @DatabaseQueried IS NULL SET @DatabaseQueried = N'None';

DECLARE @TopOffenders nvarchar(max) =
    STUFF((SELECT TOP (5) N', ' + DatabaseName + N' (' + CAST(MisalignedIndexes AS nvarchar(20)) + N')'
           FROM #PartitionAudit
           WHERE MisalignedIndexes > 0
           ORDER BY MisalignedIndexes DESC, DatabaseName
           FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'');

DECLARE @Score   int,
        @Result  nvarchar(20),
        @Finding nvarchar(max);

IF @DbCount = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No accessible, online, read-write user database was found, so partition alignment could not be assessed.';
END
ELSE IF @PartTables = 0 AND @LargeUnpart = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'No partitioned user tables exist across ' + CAST(@DbCount AS nvarchar(20))
                 + N' database(s), and no unpartitioned table reaches 50,000,000 rows, so sliding-window partitioning is not required at the current data volume.';
END
ELSE IF @PartTables = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No partitioned user tables exist across ' + CAST(@DbCount AS nvarchar(20))
                 + N' database(s), yet ' + CAST(@LargeUnpart AS nvarchar(20))
                 + N' table(s) hold 50,000,000 rows or more; load, SWITCH and purge must run as fully logged row-by-row operations.';
END
ELSE IF @MisIdx > 0
BEGIN
    SET @Score = 1;
    SET @Finding = CAST(@PartTables AS nvarchar(20)) + N' partitioned table(s) found across '
                 + CAST(@DbCount AS nvarchar(20)) + N' database(s), but ' + CAST(@MisIdx AS nvarchar(20))
                 + N' index(es) on ' + CAST(@MisTables AS nvarchar(20))
                 + N' table(s) are not aligned to the base partition scheme, which blocks ALTER TABLE ... SWITCH. Worst databases (misaligned index count): '
                 + ISNULL(@TopOffenders, N'n/a') + N'. Tables with an empty boundary partition: '
                 + CAST(@Sliding AS nvarchar(20)) + N'. Large unpartitioned tables: ' + CAST(@LargeUnpart AS nvarchar(20)) + N'.';
END
ELSE IF @Sliding = 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'All indexes on the ' + CAST(@PartTables AS nvarchar(20))
                 + N' partitioned table(s) across ' + CAST(@DbCount AS nvarchar(20))
                 + N' database(s) are aligned, but no table keeps an empty first or last partition, so the sliding window has no pre-staged partition for metadata-only load or purge. Large unpartitioned tables: '
                 + CAST(@LargeUnpart AS nvarchar(20)) + N'.';
END
ELSE
BEGIN
    SET @Score = 3;
    SET @Finding = N'All indexes on the ' + CAST(@PartTables AS nvarchar(20))
                 + N' partitioned table(s) across ' + CAST(@DbCount AS nvarchar(20))
                 + N' database(s) are aligned to their partition scheme, and ' + CAST(@Sliding AS nvarchar(20))
                 + N' table(s) keep an empty first or last partition, supporting metadata-only SWITCH for load and purge. Large unpartitioned tables: '
                 + CAST(@LargeUnpart AS nvarchar(20)) + N'.';
END

IF @FailedDbs > 0
    SET @Finding = @Finding + N' Note: ' + CAST(@FailedDbs AS nvarchar(20))
                 + N' database(s) could not be inspected due to access or state errors.';

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;

IF OBJECT_ID(N'tempdb..#PartitionAudit') IS NOT NULL DROP TABLE #PartitionAudit;
IF OBJECT_ID(N'tempdb..#DbList') IS NOT NULL DROP TABLE #DbList;