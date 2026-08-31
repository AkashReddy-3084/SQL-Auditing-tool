DECLARE @Count INT;
DECLARE @Score INT = 0;
DECLARE @Result VARCHAR(50);
DECLARE @DatabaseQueried VARCHAR(128) = ISNULL(DB_NAME(), 'None');
DECLARE @Finding VARCHAR(MAX) = 'No database found to be queried';

IF @DatabaseQueried IN ('master', 'tempdb', 'model', 'msdb')
BEGIN
    SET @DatabaseQueried = 'None';
    SET @Finding = 'No database found to be queried';
    SET @Score = 0;
END
ELSE
BEGIN
    SELECT @Count = ISNULL(COUNT(*), 0)
    FROM sys.indexes i
    JOIN sys.objects o ON i.object_id = o.object_id
    LEFT JOIN sys.dm_db_index_usage_stats s ON i.object_id = s.object_id AND i.index_id = s.index_id AND s.database_id = DB_ID()
    WHERE o.type = 'U' 
      AND i.type > 0 
      AND i.is_primary_key = 0
      AND i.is_unique_constraint = 0
      AND s.user_seeks = 0 
      AND s.user_scans = 0 
      AND s.user_lookups = 0;

    IF @Count > 0
    BEGIN
        SET @Score = 0;
        SET @Finding = CAST(@Count AS VARCHAR(10)) + ' unused index(es) found.';
    END
    ELSE
    BEGIN
        SET @Score = 3;
        SET @Finding = 'No unused indexes found.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT 
    ISNULL(@Result, 'Fail') AS Result,
    ISNULL(@Score, 0) AS Score,
    ISNULL(@DatabaseQueried, 'None') AS DatabaseQueried,
    ISNULL(@Finding, 'No database found to be queried') AS Finding;