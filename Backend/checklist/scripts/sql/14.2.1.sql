-- Checklist: Index usage analyzed (seeks vs scans) against workload
-- Scope: DATABASE
-- Scoring: 3 = no unused or scan-dominated nonclustered index; 2 = under 10 percent affected, or no nonclustered indexes exist; 1 = under 30 percent affected, or no usage statistics have accumulated; 0 = 30 percent or more affected

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Index usage statistics could not be read for the current database';
DECLARE @UsageRows INT = 0;
DECLARE @Indexes INT = 0;
DECLARE @Unused INT = 0;
DECLARE @ScanHeavy INT = 0;
DECLARE @Problem INT = 0;
DECLARE @Seeks BIGINT = 0;
DECLARE @Scans BIGINT = 0;
DECLARE @Lookups BIGINT = 0;
DECLARE @Bad NVARCHAR(MAX) = '';
DECLARE @Pct DECIMAL(9,4) = 0;
DECLARE @Readable BIT = 0;

BEGIN TRY
    SELECT @UsageRows = COUNT(*)
    FROM sys.dm_db_index_usage_stats AS u
    WHERE u.database_id = DB_ID();

    ;WITH i AS
    (
        SELECT QUOTENAME(SCHEMA_NAME(t.schema_id)) + '.' + QUOTENAME(t.name) + '.' + QUOTENAME(ix.name) AS FullName,
               ISNULL(u.user_seeks, 0) AS Seeks,
               ISNULL(u.user_scans, 0) AS Scans,
               ISNULL(u.user_lookups, 0) AS Lookups,
               ISNULL(u.user_updates, 0) AS Updates
        FROM sys.indexes AS ix
        JOIN sys.tables AS t ON t.object_id = ix.object_id
        LEFT JOIN sys.dm_db_index_usage_stats AS u
               ON u.object_id = ix.object_id
              AND u.index_id = ix.index_id
              AND u.database_id = DB_ID()
        WHERE t.is_ms_shipped = 0
          AND ix.type_desc = 'NONCLUSTERED'
          AND ix.is_primary_key = 0
          AND ix.is_unique_constraint = 0
          AND ix.name IS NOT NULL
    )
    SELECT @Indexes = COUNT(*),
           @Seeks = ISNULL(SUM(Seeks), 0),
           @Scans = ISNULL(SUM(Scans), 0),
           @Lookups = ISNULL(SUM(Lookups), 0),
           @Unused = ISNULL(SUM(CASE WHEN Seeks + Scans + Lookups = 0 THEN 1 ELSE 0 END), 0),
           @ScanHeavy = ISNULL(SUM(CASE WHEN Seeks + Scans + Lookups > 0 AND Scans > Seeks THEN 1 ELSE 0 END), 0),
           @Bad = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX),
                      CASE WHEN Seeks + Scans + Lookups = 0 THEN FullName + ' (never used)'
                           WHEN Scans > Seeks THEN FullName + ' (scan dominated)' END), ', '), 500), '')
    FROM i;

    SET @Readable = 1;
END TRY
BEGIN CATCH
    SET @Readable = 0;
END CATCH;

SET @Problem = @Unused + @ScanHeavy;
SET @Pct = ISNULL(CONVERT(DECIMAL(9,4), @Problem) / NULLIF(@Indexes, 0), 0);

SET @Score = CASE
                WHEN @Readable = 0 THEN 0
                WHEN @UsageRows = 0 THEN 1
                WHEN @Indexes = 0 THEN 2
                WHEN @Problem = 0 THEN 3
                WHEN @Pct < 0.10 THEN 2
                WHEN @Pct < 0.30 THEN 1
                ELSE 0
             END;

SET @Finding = CASE
    WHEN @Readable = 0
        THEN 'sys.dm_db_index_usage_stats could not be read, so seeks versus scans could not be analysed'
    WHEN @UsageRows = 0
        THEN 'No index usage statistics have accumulated for this database, so seek and scan behaviour cannot yet be analysed against the workload'
    WHEN @Indexes = 0
        THEN CONCAT('No user nonclustered indexes exist in this database; recorded usage across all indexes is ',
                    @Seeks, ' seeks, ', @Scans, ' scans, ', @Lookups, ' lookups')
    WHEN @Problem = 0
        THEN CONCAT('All ', @Indexes, ' nonclustered index(es) are used and seek dominated: ',
                    @Seeks, ' seeks vs ', @Scans, ' scans, ', @Lookups, ' lookups')
    ELSE CONCAT(@Problem, ' of ', @Indexes, ' nonclustered index(es) (',
                CONVERT(DECIMAL(9,1), @Pct * 100), ' percent) are unused or scan dominated (',
                @Unused, ' never used, ', @ScanHeavy, ' scanned more than sought); totals ',
                @Seeks, ' seeks vs ', @Scans, ' scans; ', @Bad)
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;