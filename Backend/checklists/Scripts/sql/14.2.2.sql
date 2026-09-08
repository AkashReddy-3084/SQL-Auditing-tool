DECLARE @Result VARCHAR(50);
DECLARE @Score INT;
DECLARE @DatabaseQueried VARCHAR(128) = 'master';
DECLARE @Finding VARCHAR(MAX) = '';

DECLARE @MissingIndexCount INT;

SELECT @MissingIndexCount = COUNT(*)
FROM sys.dm_db_missing_index_group_stats gs
JOIN sys.dm_db_missing_index_groups ig ON gs.group_handle = ig.index_group_handle
JOIN sys.dm_db_missing_index_details id ON ig.index_handle = id.index_handle;

IF @MissingIndexCount > 20
BEGIN
    SET @Score = 1;
    SET @Finding = CAST(@MissingIndexCount AS VARCHAR(20)) + ' missing index recommendations were found server-wide, suggesting a review is needed.';
END
ELSE IF @MissingIndexCount > 0
BEGIN
    SET @Score = 2;
    SET @Finding = CAST(@MissingIndexCount AS VARCHAR(20)) + ' missing index recommendations were found server-wide. Review applied judiciously.';
END
ELSE
BEGIN
    SET @Score = 3;
    SET @Finding = 'No missing index recommendations found server-wide.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT 
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;