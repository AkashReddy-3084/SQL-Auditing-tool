-- Checklist: Views used appropriately (no deeply nested view chains that hide cost)
-- Scope: DATABASE
-- Scoring: 3 = no view reads another view, or the deepest chain is 2 views; 2 = deepest chain is 3 views; 1 = chains of 4 or more views exist but head fewer than 25% of all views; 0 = 25% or more of views head a chain of 4 or more, or dependency metadata is unreadable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'View dependency metadata could not be read in this database';
DECLARE @Views INT = 0;
DECLARE @Nested INT = 0;
DECLARE @MaxDepth INT = 0;
DECLARE @Deep INT = 0;
DECLARE @DeepList NVARCHAR(MAX) = '';
DECLARE @Ratio DECIMAL(9, 4) = 0;
DECLARE @Probed BIT = 0;

BEGIN TRY
    SELECT @Views = COUNT(*) FROM sys.views WHERE is_ms_shipped = 0;

    WITH edges AS (
        SELECT d.referencing_id AS child_id, d.referenced_id AS parent_id
        FROM sys.sql_expression_dependencies AS d
        JOIN sys.views AS cv ON cv.object_id = d.referencing_id AND cv.is_ms_shipped = 0
        JOIN sys.views AS pv ON pv.object_id = d.referenced_id AND pv.is_ms_shipped = 0
        WHERE d.referencing_class = 1
          AND d.referenced_class = 1
          AND d.referenced_id <> d.referencing_id
        GROUP BY d.referencing_id, d.referenced_id
    ),
    chain AS (
        SELECT e.child_id AS root_id, e.parent_id, 2 AS depth
        FROM edges AS e
        UNION ALL
        SELECT c.root_id, n.parent_id, c.depth + 1
        FROM chain AS c
        JOIN edges AS n ON n.child_id = c.parent_id
        WHERE c.depth < 8
    ),
    roots AS (
        SELECT root_id, MAX(depth) AS depth
        FROM chain
        GROUP BY root_id
    )
    SELECT @Nested = COUNT(*),
           @MaxDepth = ISNULL(MAX(r.depth), 0),
           @Deep = ISNULL(SUM(CASE WHEN r.depth >= 4 THEN 1 ELSE 0 END), 0),
           @DeepList = ISNULL(LEFT(STRING_AGG(CASE WHEN r.depth >= 4
                                THEN CONVERT(NVARCHAR(MAX), QUOTENAME(SCHEMA_NAME(v.schema_id)) + '.'
                                     + QUOTENAME(v.name) + ' (depth ' + CONVERT(NVARCHAR(10), r.depth) + ')')
                                END, ', '), 400), '')
    FROM roots AS r
    JOIN sys.views AS v ON v.object_id = r.root_id
    OPTION (MAXRECURSION 100);

    SET @Probed = 1;
END TRY
BEGIN CATCH
    SET @Probed = 0;
END CATCH

SET @Ratio = CASE WHEN @Views = 0 THEN 0
                  ELSE CONVERT(DECIMAL(9, 4), @Deep) / @Views END;

IF @Probed = 0
    SET @Score = 0;
ELSE IF @MaxDepth <= 2
    SET @Score = 3;
ELSE IF @MaxDepth = 3
    SET @Score = 2;
ELSE IF @Ratio < 0.25
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Finding = CASE WHEN @Probed = 0
    THEN 'sys.sql_expression_dependencies could not be read in this database; VIEW DEFINITION permission is required to walk view-on-view chains.'
    ELSE CONCAT('User views = ', @Views, '; views reading another view = ', @Nested,
                '; deepest view-on-view chain = ', @MaxDepth, ' level(s); views heading a chain of 4 or more = ', @Deep,
                CASE WHEN LEN(ISNULL(@DeepList, '')) > 0 THEN CONCAT('. Deeply nested: ', @DeepList)
                     ELSE '. No view sits on a chain 4 or more levels deep' END, '.')
    END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
