SET NOCOUNT ON;

DECLARE @Result nvarchar(20);
DECLARE @Score int;
DECLARE @DatabaseQueried nvarchar(128);
DECLARE @Finding nvarchar(2000);
DECLARE @DuplicatePairCount bigint;
DECLARE @UnusedCandidateCount bigint;

IF DB_NAME() IS NULL
   OR DB_NAME() IN (N'master', N'model', N'msdb', N'tempdb')
   OR DATABASEPROPERTYEX(DB_NAME(), 'Status') <> N'ONLINE'
BEGIN
    SET @Score = 0;
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
END
ELSE
BEGIN
    SET @DatabaseQueried = DB_NAME();

    ;WITH IndexDefinitions AS
    (
        SELECT
            i.object_id,
            i.index_id,
            i.type,
            i.filter_definition,
            ISNULL(
                STUFF(
                    (
                        SELECT N',' + QUOTENAME(c.name) +
                               CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N' ASC' END
                        FROM sys.index_columns AS ic
                        INNER JOIN sys.columns AS c
                            ON c.object_id = ic.object_id
                           AND c.column_id = ic.column_id
                        WHERE ic.object_id = i.object_id
                          AND ic.index_id = i.index_id
                          AND ic.key_ordinal > 0
                        ORDER BY ic.key_ordinal
                        FOR XML PATH(''), TYPE
                    ).value('.', 'nvarchar(max)'),
                    1,
                    1,
                    N''
                ),
                N''
            ) AS KeyColumns,
            ISNULL(
                STUFF(
                    (
                        SELECT N',' + QUOTENAME(c.name)
                        FROM sys.index_columns AS ic
                        INNER JOIN sys.columns AS c
                            ON c.object_id = ic.object_id
                           AND c.column_id = ic.column_id
                        WHERE ic.object_id = i.object_id
                          AND ic.index_id = i.index_id
                          AND ic.is_included_column = 1
                        ORDER BY c.column_id
                        FOR XML PATH(''), TYPE
                    ).value('.', 'nvarchar(max)'),
                    1,
                    1,
                    N''
                ),
                N''
            ) AS IncludedColumns
        FROM sys.indexes AS i
        INNER JOIN sys.tables AS t
            ON t.object_id = i.object_id
        WHERE t.is_ms_shipped = 0
          AND i.type IN (1, 2)
          AND i.index_id > 0
          AND i.is_hypothetical = 0
          AND i.is_disabled = 0
          AND i.is_unique = 0
          AND i.is_primary_key = 0
          AND i.is_unique_constraint = 0
    ),
    DuplicatePairs AS
    (
        SELECT
            left_index.object_id,
            left_index.index_id,
            right_index.index_id AS DuplicateIndexId
        FROM IndexDefinitions AS left_index
        INNER JOIN IndexDefinitions AS right_index
            ON right_index.object_id = left_index.object_id
           AND right_index.index_id > left_index.index_id
           AND right_index.type = left_index.type
           AND right_index.KeyColumns = left_index.KeyColumns
           AND right_index.IncludedColumns = left_index.IncludedColumns
           AND ISNULL(right_index.filter_definition, N'') = ISNULL(left_index.filter_definition, N'')
    ),
    IndexRowCounts AS
    (
        SELECT
            ps.object_id,
            ps.index_id,
            SUM(ps.row_count) AS RowCount
        FROM sys.dm_db_partition_stats AS ps
        WHERE ps.index_id > 0
        GROUP BY ps.object_id, ps.index_id
    ),
    UnusedCandidates AS
    (
        SELECT
            i.object_id,
            i.index_id
        FROM sys.indexes AS i
        INNER JOIN sys.tables AS t
            ON t.object_id = i.object_id
        INNER JOIN IndexRowCounts AS rc
            ON rc.object_id = i.object_id
           AND rc.index_id = i.index_id
        INNER JOIN sys.dm_db_index_usage_stats AS us
            ON us.database_id = DB_ID()
           AND us.object_id = i.object_id
           AND us.index_id = i.index_id
        WHERE t.is_ms_shipped = 0
          AND i.type = 2
          AND i.is_hypothetical = 0
          AND i.is_disabled = 0
          AND i.is_unique = 0
          AND i.is_primary_key = 0
          AND i.is_unique_constraint = 0
          AND rc.RowCount > 0
          AND us.user_updates > 0
          AND ISNULL(us.user_seeks, 0) = 0
          AND ISNULL(us.user_scans, 0) = 0
          AND ISNULL(us.user_lookups, 0) = 0
    )
    SELECT
        @DuplicatePairCount = (SELECT COUNT_BIG(*) FROM DuplicatePairs),
        @UnusedCandidateCount = (SELECT COUNT_BIG(*) FROM UnusedCandidates);

    SET @Score = CASE
        WHEN @DuplicatePairCount > 0 THEN 1
        WHEN @UnusedCandidateCount > 0 THEN 2
        ELSE 3
    END;

    SET @Finding = CASE
        WHEN @DuplicatePairCount = 0 AND @UnusedCandidateCount = 0
            THEN N'No exact duplicate index pairs or conservative unused-index candidates were found.'
        ELSE CONCAT(
            N'Exact duplicate index pairs: ', @DuplicatePairCount,
            N'; unused nonconstraint indexes with updates but no seeks, scans, or lookups in the current usage-statistics interval: ',
            @UnusedCandidateCount,
            N'. Review workload history and maintenance requirements before removing any index.'
        )
    END;
END;

SET @Result = CASE
    WHEN @Score = 3 THEN N'Pass'
    WHEN @Score = 2 THEN N'Partial'
    ELSE N'Fail'
END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;