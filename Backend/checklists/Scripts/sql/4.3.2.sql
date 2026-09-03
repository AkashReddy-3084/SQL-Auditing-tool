-- Checklist: Columnstore indexes used for large fact tables / analytical workloads where appropriate
-- Scope: DATABASE
-- Scoring: 3 = no large/fact table lacks a columnstore index (including when none exists); 2 = under 25% uncovered; 1 = under 75%; 0 = 75% or more, or metadata unreadable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Table and index metadata could not be inspected in the current database';

DECLARE @Unreadable BIT = 0;
DECLARE @RowThreshold BIGINT = 1000000;
DECLARE @TotalTables INT = 0;
DECLARE @LargeCount INT = 0;
DECLARE @Covered INT = 0;
DECLARE @Uncovered INT = 0;
DECLARE @Examples NVARCHAR(MAX) = '';
DECLARE @Pct DECIMAL(9,2) = 0;

DECLARE @Large TABLE
(
    TableName NVARCHAR(300) NOT NULL,
    RowCnt    BIGINT NOT NULL,
    HasCs     BIT NOT NULL
);

BEGIN TRY
    SELECT @TotalTables = ISNULL(COUNT(*), 0)
    FROM sys.tables AS t
    WHERE t.is_ms_shipped = 0;

    INSERT INTO @Large (TableName, RowCnt, HasCs)
    SELECT LEFT(ISNULL(SCHEMA_NAME(t.schema_id), 'dbo') + '.' + t.name, 300),
           ISNULL(r.RowCnt, 0),
           CASE WHEN EXISTS (SELECT 1 FROM sys.indexes AS i
                             WHERE i.object_id = t.object_id AND i.type IN (5, 6))
                THEN 1 ELSE 0 END
    FROM sys.tables AS t
    OUTER APPLY (SELECT SUM(p.rows) AS RowCnt
                 FROM sys.partitions AS p
                 WHERE p.object_id = t.object_id AND p.index_id IN (0, 1)) AS r
    WHERE t.is_ms_shipped = 0
      AND (ISNULL(r.RowCnt, 0) > @RowThreshold OR t.name LIKE '%fact%');
END TRY
BEGIN CATCH
    SET @Unreadable = 1;
END CATCH

SELECT @LargeCount = ISNULL(COUNT(*), 0),
       @Covered    = ISNULL(SUM(CASE WHEN HasCs = 1 THEN 1 ELSE 0 END), 0)
FROM @Large;

SET @Uncovered = @LargeCount - @Covered;
SET @Pct = ISNULL(@Uncovered * 100.0 / NULLIF(@LargeCount, 0), 0);

SELECT @Examples = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX), TableName + ' (' + CONVERT(NVARCHAR(20), RowCnt) + ' rows)'), ', '), '')
FROM (SELECT TOP (5) TableName, RowCnt FROM @Large WHERE HasCs = 0 ORDER BY RowCnt DESC, TableName) AS ex;

IF @Unreadable = 1
BEGIN
    SET @Score = 0;
    SET @Finding = 'Table and index metadata in ' + @DatabaseQueried + ' is not readable by the audit login, so columnstore coverage could not be assessed.';
END
ELSE IF @LargeCount = 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'None of the ' + CONVERT(NVARCHAR(20), @TotalTables) + ' user table(s) in ' + @DatabaseQueried
                 + ' exceeds ' + CONVERT(NVARCHAR(30), @RowThreshold)
                 + ' rows or carries a fact-style name, so no analytical table warrants a columnstore index.';
END
ELSE IF @Uncovered = 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'All ' + CONVERT(NVARCHAR(20), @LargeCount) + ' large or fact-named table(s) in ' + @DatabaseQueried
                 + ' (of ' + CONVERT(NVARCHAR(20), @TotalTables)
                 + ' user tables) already carry a clustered or nonclustered columnstore index.';
END
ELSE
BEGIN
    SET @Score = CASE WHEN @Pct < 25 THEN 2 WHEN @Pct < 75 THEN 1 ELSE 0 END;
    SET @Finding = CONVERT(NVARCHAR(20), @Uncovered) + ' of ' + CONVERT(NVARCHAR(20), @LargeCount)
                 + ' large or fact-named table(s) in ' + @DatabaseQueried + ' (' + CONVERT(NVARCHAR(20), @Pct)
                 + '%) have no columnstore index; ' + CONVERT(NVARCHAR(20), @Covered)
                 + ' already do. Threshold used: ' + CONVERT(NVARCHAR(30), @RowThreshold)
                 + ' rows or a name containing "fact". Largest uncovered: ' + @Examples + '.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;