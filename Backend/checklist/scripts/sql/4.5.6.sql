DECLARE @Result VARCHAR(50);
DECLARE @Score INT;
DECLARE @DatabaseQueried VARCHAR(128) = DB_NAME();
DECLARE @Finding VARCHAR(MAX);

DECLARE @NullableMandatoryCount INT;

-- Proxy check: count of columns named id or key that are nullable in user tables
SELECT @NullableMandatoryCount = COUNT(*)
FROM sys.columns
WHERE (name LIKE '%id' OR name LIKE '%key')
  AND is_nullable = 1 
  AND object_id IN (SELECT object_id FROM sys.tables);

IF @NullableMandatoryCount = 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'No commonly mandatory columns (e.g. id, key) were found to be nullable.';
END
ELSE
BEGIN
    SET @Score = 1;
    SET @Finding = 'Found ' + CAST(@NullableMandatoryCount AS VARCHAR(10)) + ' commonly mandatory columns that are nullable.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT 
    @Result AS Result, 
    @Score AS Score, 
    @DatabaseQueried AS DatabaseQueried, 
    @Finding AS Finding;