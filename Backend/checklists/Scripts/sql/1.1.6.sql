-- Checklist: Single source of truth - no duplicate warehouses serving the same purpose
-- Scope: DATABASE
-- Scoring: 2 = no duplicate user table names detected; 1 = duplicate table names detected; 0 = metadata unavailable
-- NOTE: Automated evidence only; duplicate warehouse purpose and business ownership require human review.

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Duplicate table-name metadata could not be evaluated';
DECLARE @DuplicateTableNames INT = 0;

BEGIN TRY
    SELECT @DuplicateTableNames = COUNT(*)
    FROM (SELECT name FROM sys.tables WHERE is_ms_shipped = 0 GROUP BY name HAVING COUNT(*) > 1) AS duplicates;
    SET @Score = CASE WHEN @DuplicateTableNames = 0 THEN 2 ELSE 1 END;
    SET @Finding = N'dup_table_names=' + CONVERT(NVARCHAR(20), @DuplicateTableNames);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read duplicate table-name metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;