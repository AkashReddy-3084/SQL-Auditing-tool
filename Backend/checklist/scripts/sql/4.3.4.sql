-- Checklist: No redundant/duplicate/overlapping indexes
-- Scope: DATABASE
-- Scoring: 3 = no nonclustered index is duplicated or prefixed by another; 2 = under 5% affected; 1 = under 25%; 0 = 25% or more, or index metadata unreadable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Index metadata could not be inspected in the current database';

DECLARE @Unreadable BIT = 0;
DECLARE @TotalIdx INT = 0;
DECLARE @DupCount INT = 0;
DECLARE @OverlapCount INT = 0;
DECLARE @Affected INT = 0;
DECLARE @Examples NVARCHAR(MAX) = '';
DECLARE @Pct DECIMAL(9,2) = 0;

DECLARE @Idx TABLE
(
    ObjectId INT NOT NULL,
    IndexId  INT NOT NULL,
    IdxRef   NVARCHAR(400) NOT NULL,
    KeyCols  NVARCHAR(MAX) NOT NULL
);

DECLARE @Flag TABLE
(
    IdxRef  NVARCHAR(400) NOT NULL,
    Pairing NVARCHAR(400) NOT NULL,
    Issue   VARCHAR(20) NOT NULL
);

BEGIN TRY
    INSERT INTO @Idx (ObjectId, IndexId, IdxRef, KeyCols)
    SELECT i.object_id,
           i.index_id,
           LEFT(ISNULL(SCHEMA_NAME(t.schema_id), 'dbo') + '.' + t.name + '.' + i.name, 400),
           ISNULL(k.KeyCols, '')
    FROM sys.indexes AS i
    INNER JOIN sys.tables AS t ON t.object_id = i.object_id
    OUTER APPLY (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), c.name), ',') WITHIN GROUP (ORDER BY ic.key_ordinal) AS KeyCols
                 FROM sys.index_columns AS ic
                 INNER JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                 WHERE ic.object_id = i.object_id
                   AND ic.index_id = i.index_id
                   AND ic.is_included_column = 0) AS k
    WHERE t.is_ms_shipped = 0
      AND i.type = 2
      AND i.is_hypothetical = 0
      AND i.name IS NOT NULL;
END TRY
BEGIN CATCH
    SET @Unreadable = 1;
END CATCH

INSERT INTO @Flag (IdxRef, Pairing, Issue)
SELECT b.IdxRef, a.IdxRef, 'DUPLICATE'
FROM @Idx AS a
INNER JOIN @Idx AS b ON b.ObjectId = a.ObjectId AND b.IndexId > a.IndexId
WHERE a.KeyCols <> '' AND a.KeyCols = b.KeyCols;

INSERT INTO @Flag (IdxRef, Pairing, Issue)
SELECT a.IdxRef, b.IdxRef, 'OVERLAPPING'
FROM @Idx AS a
INNER JOIN @Idx AS b ON b.ObjectId = a.ObjectId AND b.IndexId <> a.IndexId
WHERE a.KeyCols <> ''
  AND LEN(b.KeyCols) > LEN(a.KeyCols)
  AND LEFT(b.KeyCols, LEN(a.KeyCols) + 1) = a.KeyCols + ',';

SELECT @TotalIdx = ISNULL(COUNT(*), 0) FROM @Idx;

SELECT @DupCount     = ISNULL(SUM(CASE WHEN Issue = 'DUPLICATE' THEN 1 ELSE 0 END), 0),
       @OverlapCount = ISNULL(SUM(CASE WHEN Issue = 'OVERLAPPING' THEN 1 ELSE 0 END), 0)
FROM @Flag;

SELECT @Affected = ISNULL(COUNT(*), 0)
FROM (SELECT DISTINCT IdxRef FROM @Flag) AS a;

SET @Pct = ISNULL(@Affected * 100.0 / NULLIF(@TotalIdx, 0), 0);

SELECT @Examples = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX), Issue + ': ' + IdxRef + ' vs ' + Pairing), '; '), '')
FROM (SELECT TOP (5) Issue, IdxRef, Pairing FROM @Flag ORDER BY Issue, IdxRef) AS ex;

IF @Unreadable = 1
BEGIN
    SET @Score = 0;
    SET @Finding = 'Index metadata in ' + @DatabaseQueried + ' is not readable by the audit login, so duplicate and overlapping indexes could not be assessed.';
END
ELSE IF @TotalIdx = 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'No nonclustered index exists on user tables in ' + @DatabaseQueried + ', so no index is redundant, duplicated or overlapping.';
END
ELSE
BEGIN
    SET @Score = CASE WHEN @Affected = 0 THEN 3 WHEN @Pct < 5 THEN 2 WHEN @Pct < 25 THEN 1 ELSE 0 END;
    SET @Finding = CONVERT(NVARCHAR(20), @Affected) + ' of ' + CONVERT(NVARCHAR(20), @TotalIdx)
                 + ' nonclustered index(es) in ' + @DatabaseQueried + ' (' + CONVERT(NVARCHAR(20), @Pct)
                 + '%) are redundant: ' + CONVERT(NVARCHAR(20), @DupCount)
                 + ' pair(s) share an identical key column list and ' + CONVERT(NVARCHAR(20), @OverlapCount)
                 + ' index(es) are a leading-key prefix of another index on the same table. '
                 + CASE WHEN @Examples = '' THEN 'No redundant index found.' ELSE 'Examples: ' + @Examples + '.' END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;