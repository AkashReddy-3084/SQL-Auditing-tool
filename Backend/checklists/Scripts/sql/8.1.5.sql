-- Checklist: Extended properties / documentation on key objects
-- Scope: DATABASE
-- Scoring: 3 = at least 75% of tables and columns have extended properties; 2 = at least 50% of either category is documented; 1 = some documentation exists; 0 = no documentation or evidence is unavailable
-- NOTE: Automated evidence measures extended-property coverage; whether the documented objects are the key objects requires human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Extended-property evidence unavailable';
DECLARE @DocumentedTableCount INT = 0;
DECLARE @TableCount INT = 0;
DECLARE @DocumentedColumnCount INT = 0;
DECLARE @ColumnCount INT = 0;
DECLARE @TableDocumentationPercent DECIMAL(6, 2) = 0.00;
DECLARE @ColumnDocumentationPercent DECIMAL(6, 2) = 0.00;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT @DocumentedTableCount = COUNT(DISTINCT ep.major_id)
    FROM sys.extended_properties AS ep
    INNER JOIN sys.tables AS t ON t.object_id = ep.major_id
    WHERE ep.class = 1
      AND ep.minor_id = 0;

    SELECT @TableCount = COUNT(*)
    FROM sys.tables
    WHERE is_ms_shipped = 0;

    SELECT @DocumentedColumnCount = COUNT(*)
    FROM sys.extended_properties AS ep
    INNER JOIN sys.columns AS c
        ON c.object_id = ep.major_id
       AND c.column_id = ep.minor_id
    INNER JOIN sys.tables AS t ON t.object_id = c.object_id
    WHERE ep.class = 1
      AND ep.minor_id > 0;

    SELECT @ColumnCount = COUNT(*)
    FROM sys.columns AS c
    INNER JOIN sys.tables AS t ON t.object_id = c.object_id
    WHERE t.is_ms_shipped = 0;
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

SET @TableDocumentationPercent = CASE
    WHEN @TableCount = 0 THEN 0.00
    ELSE CONVERT(DECIMAL(6, 2), 100.0 * @DocumentedTableCount / NULLIF(@TableCount, 0))
END;
SET @ColumnDocumentationPercent = CASE
    WHEN @ColumnCount = 0 THEN 0.00
    ELSE CONVERT(DECIMAL(6, 2), 100.0 * @DocumentedColumnCount / NULLIF(@ColumnCount, 0))
END;

SET @Score = CASE
    WHEN @ReadError = 1 THEN 0
    WHEN @TableCount = 0 AND @ColumnCount = 0 THEN 2
    WHEN @TableDocumentationPercent >= 75.00 AND @ColumnDocumentationPercent >= 75.00 THEN 3
    WHEN @TableDocumentationPercent >= 50.00 OR @ColumnDocumentationPercent >= 50.00 THEN 2
    WHEN @DocumentedTableCount > 0 OR @DocumentedColumnCount > 0 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'documented tables = ', @DocumentedTableCount, N'/', @TableCount,
    N' (', @TableDocumentationPercent, N'%)',
    N'; documented columns = ', @DocumentedColumnCount, N'/', @ColumnCount,
    N' (', @ColumnDocumentationPercent, N'%)',
    CASE WHEN @ReadError = 1 THEN N'; one or more extended-property sources could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
