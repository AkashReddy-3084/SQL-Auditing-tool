SET NOCOUNT ON;

DECLARE @Score INT = 0;
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbQueried NVARCHAR(128) = 'None';
DECLARE @Result VARCHAR(50);
DECLARE @TotalSeeks BIGINT = 0;
DECLARE @TotalScans BIGINT = 0;

IF DB_ID() > 4 AND DATABASEPROPERTYEX(DB_NAME(), 'Status') = 'ONLINE'
BEGIN
    SET @DbQueried = DB_NAME();
    
    SELECT 
        @TotalSeeks = ISNULL(SUM(user_seeks), 0),
        @TotalScans = ISNULL(SUM(user_scans), 0)
    FROM sys.dm_db_index_usage_stats
    WHERE database_id = DB_ID();

    IF @TotalSeeks + @TotalScans = 0
    BEGIN
        SET @Score = 2;
        SET @Finding = 'No user index usage statistics available for analysis yet. Needs review after workload accumulates.';
    END
    ELSE IF @TotalScans > @TotalSeeks * 2 AND @TotalScans > 1000
    BEGIN
        SET @Score = 2;
        SET @Finding = CONCAT('High ratio of index scans (', @TotalScans, ') compared to seeks (', @TotalSeeks, '). This may indicate missing covering indices or poor query performance. Manual review recommended.');
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Finding = CONCAT('Index usage appears healthy. Total seeks: ', @TotalSeeks, ', Total scans: ', @TotalScans, '.');
    END
END

SET @Result = CASE 
    WHEN @Score = 1 THEN 'Pass' 
    WHEN @Score = 2 THEN 'NeedsReview' 
    ELSE 'Fail' 
END;

SELECT 
    @Result AS Result,
    @Score AS Score,
    @DbQueried AS DatabaseQueried,
    @Finding AS Finding;