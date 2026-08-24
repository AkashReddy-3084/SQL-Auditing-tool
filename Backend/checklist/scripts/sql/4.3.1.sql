DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Score INT = 3;

IF @DatabaseQueried IN ('master', 'model', 'msdb', 'tempdb')
BEGIN
    SET @DatabaseQueried = 'None';
    SET @Score = 0;
    DECLARE @ResultSkipped VARCHAR(50);
    SET @ResultSkipped = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
    SELECT 
        @ResultSkipped AS [Result],
        @Score AS [Score],
        @DatabaseQueried AS [DatabaseQueried],
        'No database found to be queried' AS [Finding];
    RETURN;
END

DECLARE @Findings TABLE (
    FindingText NVARCHAR(MAX)
);

INSERT INTO @Findings (FindingText)
SELECT 
    'Table ' + QUOTENAME(s.name) + '.' + QUOTENAME(t.name) + ' is a heap (no clustered index) with ' + CAST(ISNULL(MAX(p.rows), 0) AS NVARCHAR(20)) + ' rows.'
FROM sys.tables t
JOIN sys.schemas s ON t.schema_id = s.schema_id
JOIN sys.indexes i ON t.object_id = i.object_id
JOIN sys.partitions p ON i.object_id = p.object_id AND i.index_id = p.index_id
WHERE i.type = 0 -- Heap
  AND t.is_ms_shipped = 0
  AND p.rows > 0
GROUP BY s.name, t.name;

IF EXISTS (SELECT 1 FROM @Findings)
BEGIN
    SET @Score = 1;
END

DECLARE @Result VARCHAR(50);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

IF @Result = 'Pass'
BEGIN
    SELECT 
        @Result AS [Result],
        @Score AS [Score],
        @DatabaseQueried AS [DatabaseQueried],
        'All checked tables have clustered indexes.' AS [Finding];
END
ELSE
BEGIN
    SELECT 
        @Result AS [Result],
        @Score AS [Score],
        @DatabaseQueried AS [DatabaseQueried],
        FindingText AS [Finding]
    FROM @Findings;
END