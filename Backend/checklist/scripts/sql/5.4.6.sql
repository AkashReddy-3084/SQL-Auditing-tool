-- Checklist: Identifiers / Keys: uniqueness verified; format consistent; no nulls in keys
-- Scope: DATABASE
-- Scoring: 3 = every table has an enforced key, no nullable key columns and consistent identifier types; 2 = under 5% of tables lack a key and at most 2 nullable key columns; 1 = under 25% of tables lack a key; 0 = 25%+ lack a key, or no user tables

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Key and identifier metadata could not be evaluated in the current database';
DECLARE @Tables INT = 0;
DECLARE @NoKey INT = 0;
DECLARE @NullableKeyCols INT = 0;
DECLARE @InconsistentNames INT = 0;
DECLARE @NoKeyList NVARCHAR(MAX) = '';
DECLARE @NullableList NVARCHAR(MAX) = '';
DECLARE @Probe INT = 1;

BEGIN TRY
    ;WITH keyed AS (
        SELECT s.name AS sch, t.name AS tbl,
               CASE WHEN EXISTS (SELECT 1 FROM sys.key_constraints AS kc
                                 WHERE kc.parent_object_id = t.object_id AND kc.type IN ('PK','UQ'))
                      OR EXISTS (SELECT 1 FROM sys.indexes AS i
                                 WHERE i.object_id = t.object_id AND i.is_unique = 1 AND i.is_disabled = 0)
                    THEN 1 ELSE 0 END AS HasKey
        FROM sys.tables AS t
        JOIN sys.schemas AS s ON s.schema_id = t.schema_id
        WHERE t.is_ms_shipped = 0
    )
    SELECT @Tables = COUNT(*),
           @NoKey = ISNULL(SUM(CASE WHEN HasKey = 0 THEN 1 ELSE 0 END), 0),
           @NoKeyList = ISNULL(LEFT(STRING_AGG(CASE WHEN HasKey = 0 THEN CONVERT(NVARCHAR(MAX), sch + '.' + tbl) END, ', '), 300), '')
    FROM keyed;

    SELECT @NullableKeyCols = COUNT(*),
           @NullableList = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), s.name + '.' + t.name + '.' + c.name), ', '), 300), '')
    FROM sys.columns AS c
    JOIN sys.tables AS t ON t.object_id = c.object_id
    JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0
      AND c.is_nullable = 1
      AND (c.name LIKE '%[_]id' OR c.name LIKE '%id' OR c.name LIKE '%key'
           OR c.name LIKE '%code' OR c.name LIKE '%number' OR c.name LIKE '%[_]no');

    SELECT @InconsistentNames = COUNT(*)
    FROM (
        SELECT c.name AS ColName
        FROM sys.columns AS c
        JOIN sys.tables AS t ON t.object_id = c.object_id
        JOIN sys.types AS ty ON ty.user_type_id = c.user_type_id
        WHERE t.is_ms_shipped = 0
          AND (c.name LIKE '%[_]id' OR c.name LIKE '%id' OR c.name LIKE '%key' OR c.name LIKE '%code')
        GROUP BY c.name
        HAVING COUNT(DISTINCT CONVERT(NVARCHAR(200), ty.name) + '(' + CONVERT(NVARCHAR(20), c.max_length) + ')') > 1
    ) AS x;
END TRY
BEGIN CATCH
    SET @Probe = 0;
    SET @Finding = 'Key metadata unavailable: ' + LEFT(ERROR_MESSAGE(), 200);
END CATCH;

SET @Tables = ISNULL(@Tables, 0);
SET @NoKey = ISNULL(@NoKey, 0);
SET @NullableKeyCols = ISNULL(@NullableKeyCols, 0);
SET @InconsistentNames = ISNULL(@InconsistentNames, 0);

DECLARE @NoKeyPct DECIMAL(9,2) = ISNULL(100.0 * @NoKey / NULLIF(@Tables, 0), 0);

IF @Probe = 1
BEGIN
    SET @Score = CASE
        WHEN @Tables = 0 THEN 0
        WHEN @NoKey = 0 AND @NullableKeyCols = 0 AND @InconsistentNames = 0 THEN 3
        WHEN @NoKeyPct < 5 AND @NullableKeyCols <= 2 THEN 2
        WHEN @NoKeyPct < 25 THEN 1
        ELSE 0 END;

    IF @Tables = 0
        SET @Finding = 'No user tables found in ' + @DatabaseQueried + '; no identifiers or keys to verify';
    ELSE
        SET @Finding = CONCAT(@DatabaseQueried, ': ', @NoKey, ' of ', @Tables, ' table(s) (',
            CONVERT(NVARCHAR(10), @NoKeyPct), '%) enforce no primary key or unique index',
            CASE WHEN LEN(@NoKeyList) > 0 THEN ' (' + @NoKeyList + ')' ELSE '' END,
            '; ', @NullableKeyCols, ' nullable key-named column(s)',
            CASE WHEN LEN(@NullableList) > 0 THEN ' (' + @NullableList + ')' ELSE '' END,
            '; ', @InconsistentNames, ' identifier name(s) declared with more than one data type');
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
