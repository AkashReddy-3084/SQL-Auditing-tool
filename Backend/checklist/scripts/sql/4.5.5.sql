DECLARE @Score INT = 3;
DECLARE @Result VARCHAR(50);
DECLARE @DatabaseQueried VARCHAR(255) = ISNULL(DB_NAME(), 'None');
DECLARE @Finding NVARCHAR(MAX) = '';

IF @DatabaseQueried = 'None' OR @DatabaseQueried IN ('master', 'model', 'msdb', 'tempdb')
BEGIN
    SET @DatabaseQueried = 'None';
    SET @Finding = 'No database found to be queried';
    SET @Score = 0;
END
ELSE
BEGIN
    DECLARE @Issues NVARCHAR(MAX);
    
    WITH Untrusted AS (
        SELECT 'Untrusted FK ' + name + ' on ' + ISNULL(OBJECT_SCHEMA_NAME(parent_object_id), '') + '.' + ISNULL(OBJECT_NAME(parent_object_id), '') AS detail
        FROM sys.foreign_keys
        WHERE is_not_trusted = 1
        UNION ALL
        SELECT 'Untrusted Check ' + name + ' on ' + ISNULL(OBJECT_SCHEMA_NAME(parent_object_id), '') + '.' + ISNULL(OBJECT_NAME(parent_object_id), '') AS detail
        FROM sys.check_constraints
        WHERE is_not_trusted = 1
    )
    SELECT @Issues = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX), detail), '; '), '')
    FROM Untrusted;

    IF LEN(@Issues) > 0
    BEGIN
        SET @Score = 1;
        SET @Finding = @Issues;
    END
    ELSE
    BEGIN
        SET @Finding = 'No untrusted constraints found.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;