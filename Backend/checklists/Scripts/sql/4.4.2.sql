SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
CREATE TABLE #Results (
    DatabaseName SYSNAME NOT NULL,
    PartitionedTableCount INT NOT NULL,
    FullyAlignedTableCount INT NOT NULL,
    MisalignedIndexCount INT NOT NULL,
    SlidingWindowCandidateCount INT NOT NULL,
    Detail NVARCHAR(MAX) NULL
);

DECLARE @Sql NVARCHAR(MAX);
DECLARE @DbName SYSNAME;
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT d.name
FROM sys.databases d
WHERE d.state = 0
  AND d.database_id > 4
  AND HAS_DBACCESS(d.name) = 1
  AND (@EngineEdition = 5 OR d.name NOT IN ('master', 'model', 'msdb', 'tempdb'))
ORDER BY d.name;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Sql = N'
    USE ' + QUOTENAME(@DbName) + N';
    SET NOCOUNT ON;

    DECLARE @PartitionedTableCount INT = 0;
    DECLARE @FullyAlignedTableCount INT = 0;
    DECLARE @MisalignedIndexCount INT = 0;
    DECLARE @SlidingWindowCandidateCount INT = 0;
    DECLARE @Detail NVARCHAR(MAX) = N'''';

    ;WITH PartitionedTables AS (
        SELECT DISTINCT
            s.name AS SchemaName,
            t.name AS TableName,
            t.object_id,
            ps.name AS PartitionSchemeName,
            pf.name AS PartitionFunctionName,
            pf.fanout AS PartitionCount,
            CASE WHEN pf.fanout >= 3 THEN 1 ELSE 0 END AS IsSlidingCandidate
        FROM sys.tables t
        INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
        INNER JOIN sys.indexes i ON i.object_id = t.object_id AND i.index_id IN (0, 1)
        INNER JOIN sys.partition_schemes ps ON ps.data_space_id = i.data_space_id
        INNER JOIN sys.partition_functions pf ON pf.function_id = ps.function_id
        WHERE t.is_ms_shipped = 0
    ),
    IndexAlignment AS (
        SELECT
            pt.object_id,
            pt.SchemaName,
            pt.TableName,
            pt.PartitionSchemeName,
            pt.PartitionFunctionName,
            pt.PartitionCount,
            pt.IsSlidingCandidate,
            SUM(CASE
                    WHEN ix.index_id > 1
                     AND (
                            ix.data_space_id <> ps_base.data_space_id
                            OR ISNULL(ds.type, '''') <> ''PS''
                         )
                    THEN 1 ELSE 0
                END) AS MisalignedSecondaryIndexes,
            COUNT(CASE WHEN ix.index_id > 1 THEN 1 END) AS SecondaryIndexCount
        FROM PartitionedTables pt
        INNER JOIN sys.indexes ix_base
            ON ix_base.object_id = pt.object_id
           AND ix_base.index_id IN (0, 1)
        INNER JOIN sys.partition_schemes ps_base
            ON ps_base.data_space_id = ix_base.data_space_id
        LEFT JOIN sys.indexes ix
            ON ix.object_id = pt.object_id
        LEFT JOIN sys.data_spaces ds
            ON ds.data_space_id = ix.data_space_id
        GROUP BY
            pt.object_id,
            pt.SchemaName,
            pt.TableName,
            pt.PartitionSchemeName,
            pt.PartitionFunctionName,
            pt.PartitionCount,
            pt.IsSlidingCandidate
    )
    SELECT
        @PartitionedTableCount = COUNT(*),
        @FullyAlignedTableCount = SUM(CASE WHEN MisalignedSecondaryIndexes = 0 THEN 1 ELSE 0 END),
        @MisalignedIndexCount = SUM(MisalignedSecondaryIndexes),
        @SlidingWindowCandidateCount = SUM(CASE WHEN IsSlidingCandidate = 1 THEN 1 ELSE 0 END)
    FROM IndexAlignment;

    IF @PartitionedTableCount = 0
    BEGIN
        SET @Detail = N''No partitioned user tables found'';
    END
    ELSE
    BEGIN
        ;WITH PartitionedTables AS (
            SELECT DISTINCT
                s.name AS SchemaName,
                t.name AS TableName,
                t.object_id,
                ps.name AS PartitionSchemeName,
                pf.name AS PartitionFunctionName,
                pf.fanout AS PartitionCount
            FROM sys.tables t
            INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
            INNER JOIN sys.indexes i ON i.object_id = t.object_id AND i.index_id IN (0, 1)
            INNER JOIN sys.partition_schemes ps ON ps.data_space_id = i.data_space_id
            INNER JOIN sys.partition_functions pf ON pf.function_id = ps.function_id
            WHERE t.is_ms_shipped = 0
        ),
        IndexAlignment AS (
            SELECT
                pt.SchemaName,
                pt.TableName,
                pt.PartitionSchemeName,
                pt.PartitionFunctionName,
                pt.PartitionCount,
                SUM(CASE
                        WHEN ix.index_id > 1
                         AND (
                                ix.data_space_id <> ps_base.data_space_id
                                OR ISNULL(ds.type, '''') <> ''PS''
                             )
                        THEN 1 ELSE 0
                    END) AS MisalignedSecondaryIndexes
            FROM PartitionedTables pt
            INNER JOIN sys.indexes ix_base
                ON ix_base.object_id = pt.object_id
               AND ix_base.index_id IN (0, 1)
            INNER JOIN sys.partition_schemes ps_base
                ON ps_base.data_space_id = ix_base.data_space_id
            LEFT JOIN sys.indexes ix
                ON ix.object_id = pt.object_id
            LEFT JOIN sys.data_spaces ds
                ON ds.data_space_id = ix.data_space_id
            GROUP BY
                pt.SchemaName,
                pt.TableName,
                pt.PartitionSchemeName,
                pt.PartitionFunctionName,
                pt.PartitionCount
        )
        SELECT @Detail = STUFF((
            SELECT TOP (15) ''; '' +
                ia.SchemaName + ''.'' + ia.TableName +
                '' [pf='' + ia.PartitionFunctionName +
                '', ps='' + ia.PartitionSchemeName +
                '', partitions='' + CAST(ia.PartitionCount AS NVARCHAR(20)) +
                '', misaligned_nc='' + CAST(ia.MisalignedSecondaryIndexes AS NVARCHAR(20)) + '']''
            FROM IndexAlignment ia
            ORDER BY ia.MisalignedSecondaryIndexes DESC, ia.PartitionCount ASC, ia.SchemaName, ia.TableName
            FOR XML PATH(''''), TYPE
        ).value(''.'', ''NVARCHAR(MAX)''), 1, 2, '''');
    END

    INSERT INTO #Results (DatabaseName, PartitionedTableCount, FullyAlignedTableCount, MisalignedIndexCount, SlidingWindowCandidateCount, Detail)
    VALUES (
        N''' + REPLACE(@DbName, '''', '''''') + N''',
        @PartitionedTableCount,
        ISNULL(@FullyAlignedTableCount, 0),
        ISNULL(@MisalignedIndexCount, 0),
        ISNULL(@SlidingWindowCandidateCount, 0),
        @Detail
    );
    ';

    BEGIN TRY
        EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #Results (DatabaseName, PartitionedTableCount, FullyAlignedTableCount, MisalignedIndexCount, SlidingWindowCandidateCount, Detail)
        VALUES (@DbName, -1, 0, 0, 0, LEFT(ERROR_MESSAGE(), 400));
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @DbName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

DECLARE @DatabasesQueried INT = (SELECT COUNT(*) FROM #Results WHERE PartitionedTableCount >= 0);
DECLARE @ErrorCount INT = (SELECT COUNT(*) FROM #Results WHERE PartitionedTableCount < 0);
DECLARE @DbWithPartitions INT = (SELECT COUNT(*) FROM #Results WHERE PartitionedTableCount > 0);
DECLARE @TotalPartitionedTables INT = (SELECT ISNULL(SUM(CASE WHEN PartitionedTableCount > 0 THEN PartitionedTableCount ELSE 0 END), 0) FROM #Results);
DECLARE @TotalFullyAligned INT = (SELECT ISNULL(SUM(CASE WHEN PartitionedTableCount > 0 THEN FullyAlignedTableCount ELSE 0 END), 0) FROM #Results);
DECLARE @TotalMisaligned INT = (SELECT ISNULL(SUM(CASE WHEN PartitionedTableCount > 0 THEN MisalignedIndexCount ELSE 0 END), 0) FROM #Results);
DECLARE @TotalSliding INT = (SELECT ISNULL(SUM(CASE WHEN PartitionedTableCount > 0 THEN SlidingWindowCandidateCount ELSE 0 END), 0) FROM #Results);

DECLARE @Result NVARCHAR(20);
DECLARE @Score INT;
DECLARE @Finding NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);

IF @DatabasesQueried = 0 AND @ErrorCount > 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'Unable to evaluate partition alignment; all accessible database checks failed.';
    SET @DatabaseQueried = N'none';
END
ELSE IF @TotalPartitionedTables = 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'No partitioned user tables found in accessible databases; partition alignment / sliding-window SWITCH pattern is not applicable (N/A pass). Databases checked: ' + CAST(@DatabasesQueried AS NVARCHAR(20)) + N'.';
    SET @DatabaseQueried = CASE WHEN @DatabasesQueried = 0 THEN N'none' ELSE N'all_accessible' END;
END
ELSE IF @TotalMisaligned = 0 AND @TotalSliding = @TotalPartitionedTables AND @TotalFullyAligned = @TotalPartitionedTables
BEGIN
    SET @Score = 3;
    SET @Finding = N'All ' + CAST(@TotalPartitionedTables AS NVARCHAR(20)) + N' partitioned table(s) across ' + CAST(@DbWithPartitions AS NVARCHAR(20)) + N' database(s) have aligned secondary indexes and multi-partition (>=3) schemes suitable for SWITCH-based sliding-window load/purge.';
    SET @DatabaseQueried = N'all_accessible';
END
ELSE IF @TotalMisaligned = 0 AND @TotalSliding > 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'Partitioned tables are index-aligned, but only ' + CAST(@TotalSliding AS NVARCHAR(20)) + N' of ' + CAST(@TotalPartitionedTables AS NVARCHAR(20)) + N' have >=3 partitions for a practical sliding window. Review boundary management for SWITCH load/purge.';
    SET @DatabaseQueried = N'all_accessible';
END
ELSE IF @TotalMisaligned > 0 AND @TotalFullyAligned > 0
BEGIN
    SET @Score = 2;
    SET @Finding = N'Partial alignment: ' + CAST(@TotalFullyAligned AS NVARCHAR(20)) + N'/' + CAST(@TotalPartitionedTables AS NVARCHAR(20)) + N' partitioned tables fully aligned; misaligned nonclustered index references=' + CAST(@TotalMisaligned AS NVARCHAR(20)) + N'; sliding-window candidates=' + CAST(@TotalSliding AS NVARCHAR(20)) + N'. Misalignment blocks efficient partition SWITCH.';
    SET @DatabaseQueried = N'all_accessible';
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = N'Partition alignment does not support reliable SWITCH load/purge. Partitioned tables=' + CAST(@TotalPartitionedTables AS NVARCHAR(20)) + N', fully aligned=' + CAST(@TotalFullyAligned AS NVARCHAR(20)) + N', misaligned NC index refs=' + CAST(@TotalMisaligned AS NVARCHAR(20)) + N', sliding-window candidates (>=3 partitions)=' + CAST(@TotalSliding AS NVARCHAR(20)) + N'.';
    SET @DatabaseQueried = N'all_accessible';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

IF EXISTS (SELECT 1 FROM #Results WHERE PartitionedTableCount > 0 AND Detail IS NOT NULL)
BEGIN
    DECLARE @Samples NVARCHAR(MAX);
    SELECT @Samples = STUFF((
        SELECT TOP (8) N' | ' + r.DatabaseName + N': ' + r.Detail
        FROM #Results r
        WHERE r.PartitionedTableCount > 0 AND r.Detail IS NOT NULL
        ORDER BY r.MisalignedIndexCount DESC, r.DatabaseName
        FOR XML PATH(''), TYPE
    ).value('.', 'NVARCHAR(MAX)'), 1, 3, '');

    IF @Samples IS NOT NULL AND LEN(@Samples) > 0
        SET @Finding = @Finding + N' Samples: ' + @Samples;
END

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;

DROP TABLE #Results;