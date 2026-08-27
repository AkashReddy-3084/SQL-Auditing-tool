-- Checklist: Dates: valid ranges; consistent handling; no invalid future dates where prohibited
-- Scope: DATABASE
-- Scoring: 2 = date columns have validation checks and no legacy types; 1 = date columns exist with incomplete validation; 0 = no date columns or metadata unavailable
-- NOTE: Automated evidence only; data values and prohibited future-date rules require human review.

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Date-handling metadata could not be evaluated';
DECLARE @DateColumns INT = 0;
DECLARE @DateChecks INT = 0;
DECLARE @LegacyDateColumns INT = 0;

BEGIN TRY
    SELECT @DateColumns = COUNT(*)
    FROM sys.columns AS c JOIN sys.tables AS t ON t.object_id = c.object_id
    JOIN sys.types AS ty ON ty.user_type_id = c.user_type_id
    WHERE t.is_ms_shipped = 0 AND ty.name IN ('date', 'datetime', 'datetime2', 'smalldatetime', 'datetimeoffset');
    SELECT @DateChecks = COUNT(*)
    FROM sys.check_constraints AS cc JOIN sys.columns AS c ON c.object_id = cc.parent_object_id AND c.column_id = cc.parent_column_id
    JOIN sys.types AS ty ON ty.user_type_id = c.user_type_id
    WHERE ty.name IN ('date', 'datetime', 'datetime2', 'smalldatetime', 'datetimeoffset');
    SELECT @LegacyDateColumns = COUNT(*)
    FROM sys.columns AS c JOIN sys.tables AS t ON t.object_id = c.object_id
    JOIN sys.types AS ty ON ty.user_type_id = c.user_type_id
    WHERE t.is_ms_shipped = 0 AND ty.name IN ('datetime', 'smalldatetime');
    SET @Score = CASE WHEN @DateColumns = 0 THEN 0 WHEN @DateChecks > 0 AND @LegacyDateColumns = 0 THEN 2 WHEN @DateColumns > 0 THEN 1 ELSE 0 END;
    SET @Finding = N'date_cols=' + CONVERT(NVARCHAR(20), @DateColumns) + N', date_checks=' + CONVERT(NVARCHAR(20), @DateChecks) + N', legacy_date_cols=' + CONVERT(NVARCHAR(20), @LegacyDateColumns);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read date-handling metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;