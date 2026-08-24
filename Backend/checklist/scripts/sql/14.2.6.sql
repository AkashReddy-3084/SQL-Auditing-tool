SET NOCOUNT ON;

DECLARE @DatabaseQueried nvarchar(128) = DB_NAME();
DECLARE @QualifyingIndexes int = 0;
DECLARE @TunedIndexes int = 0;
DECLARE @DefaultFillFactorIndexes int = 0;
DECLARE @TunedPercent decimal(5,2) = 100.00;
DECLARE @Score int = 0;
DECLARE @Result nvarchar(20) = N'Fail';
DECLARE @Finding nvarchar(4000);

IF DB_ID() IS NULL OR DB_ID() <= 4
BEGIN
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
    SET @Score = 0;
END
ELSE
BEGIN
    BEGIN TRY
        IF OBJECT_ID('tempdb..#FillFactorEvidence') IS NOT NULL
            DROP TABLE #FillFactorEvidence;

        CREATE TABLE #FillFactorEvidence
        (
            SchemaName sysname NOT NULL,
            TableName sysname NOT NULL,
            IndexName sysname NOT NULL,
            FillFactor tinyint NOT NULL,
            LeafWrites bigint NOT NULL,
            LeafAllocations bigint NOT NULL
        );

        INSERT INTO #FillFactorEvidence
        (
            SchemaName,
            TableName,
            IndexName,
            FillFactor,
            LeafWrites,
            LeafAllocations
        )
        SELECT
            s.name,
            t.name,
            i.name,
            i.fill_factor,
            CONVERT(bigint, ios.leaf_insert_count)
                + CONVERT(bigint, ios.leaf_update_count)
                + CONVERT(bigint, ios.leaf_delete_count),
            CONVERT(bigint, ios.leaf_allocation_count)
        FROM sys.tables AS t
        INNER JOIN sys.schemas AS s
            ON s.schema_id = t.schema_id
        INNER JOIN sys.indexes AS i
            ON i.object_id = t.object_id
        INNER JOIN sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) AS ios
            ON ios.object_id = i.object_id
           AND ios.index_id = i.index_id
        WHERE t.is_ms_shipped = 0
          AND i.type IN (1, 2)
          AND i.is_disabled = 0
          AND i.is_hypothetical = 0
          AND i.name IS NOT NULL
          AND CONVERT(bigint, ios.leaf_insert_count)
                + CONVERT(bigint, ios.leaf_update_count)
                + CONVERT(bigint, ios.leaf_delete_count) >= 1000
          AND CONVERT(bigint, ios.leaf_allocation_count) >= 100
          AND CONVERT(decimal(19,4), ios.leaf_allocation_count)
                / NULLIF(CONVERT(decimal(19,4), CONVERT(bigint, ios.leaf_insert_count)
                    + CONVERT(bigint, ios.leaf_update_count)), 0) >= 0.05;

        SELECT
            @QualifyingIndexes = COUNT(*),
            @TunedIndexes = COALESCE(SUM(CASE WHEN FillFactor BETWEEN 70 AND 99 THEN 1 ELSE 0 END), 0),
            @DefaultFillFactorIndexes = COALESCE(SUM(CASE WHEN FillFactor IN (0, 100) THEN 1 ELSE 0 END), 0)
        FROM #FillFactorEvidence;

        SET @TunedPercent = CASE
            WHEN @QualifyingIndexes = 0 THEN 100.00
            ELSE CONVERT(decimal(5,2), 100.0 * @TunedIndexes / @QualifyingIndexes)
        END;

        SET @Score = CASE
            WHEN @QualifyingIndexes = 0 OR @TunedIndexes = @QualifyingIndexes THEN 3
            WHEN @TunedPercent >= 75.00 THEN 2
            WHEN @TunedPercent >= 50.00 THEN 1
            ELSE 0
        END;

        SET @Finding = CASE
            WHEN @QualifyingIndexes = 0 THEN
                N'No write-heavy rowstore indexes met the allocation-pressure thresholds during the current DMV observation window.'
            ELSE
                CONCAT(
                    N'Qualifying indexes: ', @QualifyingIndexes,
                    N'; tuned fill factor 70-99: ', @TunedIndexes,
                    N' (', @TunedPercent, N'%); default effective fill factor 100: ',
                    @DefaultFillFactorIndexes,
                    N'. Operational counters reset when the database engine restarts or the database is cycled.'
                )
        END;
    END TRY
    BEGIN CATCH
        SET @Score = 0;
        SET @Finding = CONCAT(
            N'Unable to inspect index fill-factor evidence. Error ',
            ERROR_NUMBER(), N': ', ERROR_MESSAGE()
        );
    END CATCH;
END;

SET @Result = CASE
    WHEN @Score = 3 THEN N'Pass'
    WHEN @Score IN (1, 2) THEN N'Partial'
    ELSE N'Fail'
END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;