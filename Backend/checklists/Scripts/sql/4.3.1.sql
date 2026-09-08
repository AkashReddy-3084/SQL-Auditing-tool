-- Checklist: Every table has an appropriate clustered index (or deliberate heap justification)
-- Scope: DATABASE
-- Scoring: 3 = no heaps; 2 = under 5% of user tables are heaps; 1 = under 25%; 0 = 25% or more, or tables unreadable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'User tables could not be inspected in the current database';

DECLARE @Unreadable BIT = 0;
DECLARE @TotalTables INT = 0;
DECLARE @HeapCount INT = 0;
DECLARE @HeapRows BIGINT = 0;
DECLARE @Examples NVARCHAR(MAX) = '';
DECLARE @Pct DECIMAL(9,2) = 0;

DECLARE @Heaps TABLE
(
    TableName NVARCHAR(300) NOT NULL,
    RowCnt    BIGINT NOT NULL
);

BEGIN TRY
    SELECT @TotalTables = ISNULL(COUNT(*), 0)
    FROM sys.tables AS t
    WHERE t.is_ms_shipped = 0;

    INSERT INTO @Heaps (TableName, RowCnt)
    SELECT LEFT(ISNULL(SCHEMA_NAME(t.schema_id), 'dbo') + '.' + t.name, 300),
           ISNULL((SELECT SUM(p.rows) FROM sys.partitions AS p
                   WHERE p.object_id = t.object_id AND p.index_id IN (0, 1)), 0)
    FROM sys.tables AS t
    WHERE t.is_ms_shipped = 0
      AND NOT EXISTS (SELECT 1 FROM sys.indexes AS i
                      WHERE i.object_id = t.object_id AND i.index_id = 1)
      AND NOT EXISTS (SELECT 1 FROM sys.indexes AS cs
                      WHERE cs.object_id = t.object_id AND cs.type IN (5, 6));
END TRY
BEGIN CATCH
    SET @Unreadable = 1;
END CATCH

SELECT @HeapCount = ISNULL(COUNT(*), 0),
       @HeapRows  = ISNULL(SUM(RowCnt), 0)
FROM @Heaps;

SELECT @Examples = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX), TableName + ' (' + CONVERT(NVARCHAR(20), RowCnt) + ' rows)'), ', '), '')
FROM (SELECT TOP (5) TableName, RowCnt FROM @Heaps ORDER BY RowCnt DESC, TableName) AS ex;

SET @Pct = ISNULL(@HeapCount * 100.0 / NULLIF(@TotalTables, 0), 0);

IF @Unreadable = 1
BEGIN
    SET @Score = 0;
    SET @Finding = 'Table and index metadata in ' + @DatabaseQueried + ' is not readable by the audit login, so clustered index coverage could not be assessed.';
END
ELSE IF @TotalTables = 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'No user tables found in ' + @DatabaseQueried + ', so there is no table without a clustered index.';
END
ELSE IF @HeapCount = 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'All ' + CONVERT(NVARCHAR(20), @TotalTables) + ' user table(s) in ' + @DatabaseQueried
                 + ' carry a clustered rowstore or clustered columnstore index; no heap was found.';
END
ELSE
BEGIN
    SET @Score = CASE WHEN @Pct < 5 THEN 2 WHEN @Pct < 25 THEN 1 ELSE 0 END;
    SET @Finding = CONVERT(NVARCHAR(20), @HeapCount) + ' of ' + CONVERT(NVARCHAR(20), @TotalTables)
                 + ' user table(s) in ' + @DatabaseQueried + ' (' + CONVERT(NVARCHAR(20), @Pct)
                 + '%) are heaps with no clustered index and no columnstore index, holding '
                 + CONVERT(NVARCHAR(30), @HeapRows) + ' row(s) in total. Largest heaps: ' + @Examples + '.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;