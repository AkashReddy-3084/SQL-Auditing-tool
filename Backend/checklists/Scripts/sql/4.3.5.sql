DECLARE @Result VARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried VARCHAR(128) = DB_NAME();
DECLARE @Finding VARCHAR(MAX);
DECLARE @UnusedCount INT;

IF DB_ID() > 4
BEGIN
    SELECT @UnusedCount = ISNULL(COUNT(i.index_id), 0)
    FROM sys.indexes i
    INNER JOIN sys.objects o ON i.object_id = o.object_id
    LEFT JOIN sys.dm_db_index_usage_stats s 
        ON s.object_id = i.object_id 
        AND s.index_id = i.index_id 
        AND s.database_id = DB_ID()
    WHERE o.type = 'U' 
      AND i.type > 1
      AND i.is_primary_key = 0
      AND i.is_unique_constraint = 0
      AND (s.user_seeks = 0 AND s.user_scans = 0 AND s.user_lookups = 0)
      AND s.user_updates > 0;

    IF @UnusedCount > 0
    BEGIN
        SET @Score = 1;
        SET @Finding = CAST(@UnusedCount AS VARCHAR(10)) + ' unused index(es) with write overhead found.';
    END
    ELSE
    BEGIN
        SET @Score = 3;
        SET @Finding = 'No unused indexes with write overhead found.';
    END
END
ELSE
BEGIN
    SET @Score = 0;
    SET @DatabaseQueried = 'None';
    SET @Finding = 'No database found to be queried';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;