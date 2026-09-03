-- Checklist: Star schema implemented (fact + dimension tables, not flat wide tables)
-- Scope: DATABASE
-- Scoring: 3 = fact and dimension tables exist with no wide tables; 2 = both exist with wide tables, or one type exists without wide tables; 1 = only one type exists with wide tables, or tables exist without either type; 0 = no tables or evidence is unavailable
-- NOTE: Automated evidence uses table-name patterns and column counts as a schema proxy; architectural intent requires human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Schema evidence unavailable';
DECLARE @DimensionTableCount INT = 0;
DECLARE @FactTableCount INT = 0;
DECLARE @TableCount INT = 0;
DECLARE @WideTableCount INT = 0;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT @DimensionTableCount = COUNT(*)
    FROM sys.tables
    WHERE is_ms_shipped = 0
      AND (name LIKE N'Dim%' OR name LIKE N'%[_]dim' OR name LIKE N'D[_]%');

    SELECT @FactTableCount = COUNT(*)
    FROM sys.tables
    WHERE is_ms_shipped = 0
      AND (name LIKE N'Fact%' OR name LIKE N'%[_]fact' OR name LIKE N'F[_]%');

    SELECT @TableCount = COUNT(*)
    FROM sys.tables
    WHERE is_ms_shipped = 0;

    SELECT @WideTableCount = COUNT(*)
    FROM
    (
        SELECT t.object_id
        FROM sys.tables AS t
        INNER JOIN sys.columns AS c ON c.object_id = t.object_id
        WHERE t.is_ms_shipped = 0
        GROUP BY t.object_id
        HAVING COUNT(*) > 50
    ) AS wide_tables;
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

SET @Score = CASE
    WHEN @ReadError = 1 OR @TableCount = 0 THEN 0
    WHEN @DimensionTableCount > 0 AND @FactTableCount > 0 AND @WideTableCount = 0 THEN 3
    WHEN @DimensionTableCount > 0 AND @FactTableCount > 0
      OR (@WideTableCount = 0 AND (@DimensionTableCount > 0 OR @FactTableCount > 0)) THEN 2
    WHEN @DimensionTableCount > 0 OR @FactTableCount > 0 THEN 1
    WHEN @TableCount > 0 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'dimension tables = ', @DimensionTableCount,
    N'; fact tables = ', @FactTableCount,
    N'; user tables = ', @TableCount,
    N'; wide tables (>50 columns) = ', @WideTableCount,
    CASE WHEN @ReadError = 1 THEN N'; one or more catalog sources could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
