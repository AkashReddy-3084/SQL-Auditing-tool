-- Checklist: Schema-qualified object references (dbo.Table, not Table)
-- Scope: DATABASE
-- Scoring: 3 = every resolved module reference carries a schema name; 2 = under 5% of references are single-part; 1 = under 25%; 0 = 25% or more, or dependency metadata is unreadable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Module dependency metadata could not be read in this database';
DECLARE @TotalRefs INT = 0;
DECLARE @Unqualified INT = 0;
DECLARE @Modules INT = 0;
DECLARE @OffenderList NVARCHAR(MAX) = '';
DECLARE @Ratio DECIMAL(9, 4) = 0;
DECLARE @Probed BIT = 0;

BEGIN TRY
    SELECT @TotalRefs = COUNT(*),
           @Unqualified = ISNULL(SUM(CASE WHEN d.referenced_schema_name IS NULL THEN 1 ELSE 0 END), 0)
    FROM sys.sql_expression_dependencies AS d
    JOIN sys.objects AS o ON o.object_id = d.referencing_id
    WHERE o.is_ms_shipped = 0
      AND d.referenced_class = 1
      AND d.referenced_server_name IS NULL
      AND d.referenced_database_name IS NULL
      AND d.is_ambiguous = 0;

    SELECT @Modules = COUNT(*),
           @OffenderList = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), q.objname), ', '), 400), '')
    FROM (
        SELECT DISTINCT QUOTENAME(SCHEMA_NAME(o.schema_id)) + '.' + QUOTENAME(o.name) AS objname
        FROM sys.sql_expression_dependencies AS d
        JOIN sys.objects AS o ON o.object_id = d.referencing_id
        WHERE o.is_ms_shipped = 0
          AND d.referenced_class = 1
          AND d.referenced_server_name IS NULL
          AND d.referenced_database_name IS NULL
          AND d.is_ambiguous = 0
          AND d.referenced_schema_name IS NULL
    ) AS q;

    SET @Probed = 1;
END TRY
BEGIN CATCH
    SET @Probed = 0;
END CATCH

SET @Ratio = CASE WHEN @TotalRefs = 0 THEN 0
                  ELSE CONVERT(DECIMAL(9, 4), @Unqualified) / @TotalRefs END;

IF @Probed = 0
    SET @Score = 0;
ELSE IF @Unqualified = 0
    SET @Score = 3;
ELSE IF @Ratio < 0.05
    SET @Score = 2;
ELSE IF @Ratio < 0.25
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Finding = CASE WHEN @Probed = 0
    THEN 'sys.sql_expression_dependencies could not be read in this database; VIEW DEFINITION permission is required to resolve object references.'
    ELSE CONCAT('Inspected ', @TotalRefs, ' resolved object reference(s) in user modules; ',
                @Unqualified, ' use a single-part name with no schema (',
                CONVERT(NVARCHAR(20), CONVERT(DECIMAL(9, 2), @Ratio * 100)), '%), across ',
                @Modules, ' module(s)',
                CASE WHEN LEN(ISNULL(@OffenderList, '')) > 0 THEN CONCAT(': ', @OffenderList)
                     ELSE '. No module uses an unqualified reference' END, '.')
    END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
