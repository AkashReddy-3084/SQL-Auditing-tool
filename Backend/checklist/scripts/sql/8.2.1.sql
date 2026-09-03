-- Checklist: Every table/dataset has a defined data owner
-- Scope: DATABASE
-- Scoring: 3 = every user table carries a non-empty owner/steward/custodian extended property, or the database has no user tables; 2 = at least 80% do; 1 = at least 25% do, or an ownership/catalog registry table exists; 0 = under 25% and no ownership registry

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Table ownership metadata could not be inspected in this database';
DECLARE @Total INT = 0;
DECLARE @Owned INT = 0;
DECLARE @Explicit INT = 0;
DECLARE @Registry INT = 0;
DECLARE @Unowned NVARCHAR(MAX) = '';
DECLARE @RegNames NVARCHAR(MAX) = '';

WITH tbl AS (
    SELECT s.name + '.' + t.name AS FullName,
           t.principal_id,
           CASE WHEN EXISTS (
                    SELECT 1
                    FROM sys.extended_properties AS ep
                    WHERE ep.class = 1
                      AND ep.major_id = t.object_id
                      AND ep.minor_id = 0
                      AND (ep.name LIKE '%owner%' OR ep.name LIKE '%steward%' OR ep.name LIKE '%custodian%')
                      AND LEN(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(4000), ep.value), '')))) > 0)
                THEN 1 ELSE 0 END AS HasOwner
    FROM sys.tables AS t
    JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0
      AND t.temporal_type <> 1
)
SELECT @Total = COUNT(*),
       @Owned = ISNULL(SUM(HasOwner), 0),
       @Explicit = ISNULL(SUM(CASE WHEN principal_id IS NOT NULL THEN 1 ELSE 0 END), 0),
       @Unowned = ISNULL(LEFT(STRING_AGG(CASE WHEN HasOwner = 0 THEN CONVERT(NVARCHAR(MAX), FullName) END, ', '), 400), '')
FROM tbl;

SELECT @Registry = COUNT(*),
       @RegNames = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), s.name + '.' + t.name), ', '), 200), '')
FROM sys.tables AS t
JOIN sys.schemas AS s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
  AND (t.name LIKE '%data[_]owner%' OR t.name LIKE '%dataowner%' OR t.name LIKE '%steward%'
    OR t.name LIKE '%ownership%' OR t.name LIKE '%data[_]catalog%' OR t.name LIKE '%glossary%');

SET @Score = CASE
    WHEN @Total = 0 THEN 3
    WHEN @Owned = @Total THEN 3
    WHEN CONVERT(DECIMAL(9, 4), @Owned) / NULLIF(@Total, 0) >= 0.80 THEN 2
    WHEN CONVERT(DECIMAL(9, 4), @Owned) / NULLIF(@Total, 0) >= 0.25 THEN 1
    WHEN @Registry > 0 THEN 1
    ELSE 0 END;

SET @Finding = CASE
    WHEN @Total = 0 THEN 'This database contains no user tables, so no dataset is missing a defined data owner'
    ELSE CONCAT(@Owned, ' of ', @Total,
        ' user table(s) carry a non-empty owner/steward/custodian extended property; ',
        @Explicit, ' table(s) have an explicit table-level owner principal; ',
        'ownership/catalog registry tables found = ', @Registry,
        CASE WHEN LEN(@RegNames) > 0 THEN ' (' + @RegNames + ')' ELSE '' END,
        CASE WHEN LEN(@Unowned) > 0 THEN '. Tables with no recorded data owner: ' + @Unowned ELSE '' END)
    END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;