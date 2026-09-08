SET NOCOUNT ON;

DECLARE @ColumnstoreIndexCount int = 0;
DECLARE @CompressedRowgroupCount int = 0;
DECLARE @UndersizedRowgroupCount int = 0;
DECLARE @HighDeleteRowgroupCount int = 0;
DECLARE @ClosedDeltaStoreCount int = 0;
DECLARE @Score int;
DECLARE @Result nvarchar(20);
DECLARE @DatabaseQueried sysname;
DECLARE @Finding nvarchar(2048);

IF DB_ID() <= 4
BEGIN
    SET @Score = 0;
    SET @Result = N'Fail';
    SET @DatabaseQueried = 'None';
    SET @Finding = 'No database found to be queried';
END
ELSE
BEGIN
    SET @DatabaseQueried = DB_NAME();

    SELECT @ColumnstoreIndexCount = COUNT(*)
    FROM sys.indexes AS i
    INNER JOIN sys.objects AS o
        ON o.object_id = i.object_id
    WHERE i.type IN (5, 6)
      AND i.is_hypothetical = 0
      AND o.type = 'U'
      AND o.is_ms_shipped = 0;

    SELECT
        @CompressedRowgroupCount = COALESCE(SUM(CASE WHEN rg.state_desc = N'COMPRESSED' THEN 1 ELSE 0 END), 0),
        @UndersizedRowgroupCount = COALESCE(SUM(CASE
            WHEN rg.state_desc = N'COMPRESSED'
             AND rg.total_rows < 102400
             AND COALESCE(rg.trim_reason_desc, N'UNKNOWN') <> N'DICTIONARY_SIZE'
            THEN 1 ELSE 0 END), 0),
        @HighDeleteRowgroupCount = COALESCE(SUM(CASE
            WHEN rg.state_desc = N'COMPRESSED'
             AND rg.total_rows > 0
             AND CONVERT(decimal(19, 4), rg.deleted_rows) / CONVERT(decimal(19, 4), rg.total_rows) >= 0.20
            THEN 1 ELSE 0 END), 0),
        @ClosedDeltaStoreCount = COALESCE(SUM(CASE WHEN rg.state_desc = N'CLOSED' THEN 1 ELSE 0 END), 0)
    FROM sys.dm_db_column_store_row_group_physical_stats AS rg
    INNER JOIN sys.indexes AS i
        ON i.object_id = rg.object_id
       AND i.index_id = rg.index_id
    INNER JOIN sys.objects AS o
        ON o.object_id = i.object_id
    WHERE i.type IN (5, 6)
      AND i.is_hypothetical = 0
      AND o.type = 'U'
      AND o.is_ms_shipped = 0;

    IF @ColumnstoreIndexCount = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = N'Columnstore indexes are not used in this database; the rowgroup-health control is not applicable.';
    END
    ELSE
    BEGIN
        SET @Score = CASE
            WHEN @HighDeleteRowgroupCount > 0 OR @ClosedDeltaStoreCount >= 10 THEN 0
            WHEN @ClosedDeltaStoreCount > 0
              OR (@CompressedRowgroupCount > 0
                  AND @UndersizedRowgroupCount * 4 >= @CompressedRowgroupCount) THEN 1
            WHEN @UndersizedRowgroupCount > 0 THEN 2
            ELSE 3
        END;

        SET @Finding = CONCAT(
            N'Columnstore indexes: ', @ColumnstoreIndexCount,
            N'; compressed rowgroups: ', @CompressedRowgroupCount,
            N'; undersized compressed rowgroups: ', @UndersizedRowgroupCount,
            N'; compressed rowgroups with at least 20% deleted rows: ', @HighDeleteRowgroupCount,
            N'; CLOSED delta stores awaiting tuple-mover compression: ', @ClosedDeltaStoreCount,
            N'.'
        );
    END;

    SET @Result = CASE
        WHEN @Score = 3 THEN N'Pass'
        WHEN @Score = 0 THEN N'Fail'
        ELSE N'Partial'
    END;
END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;