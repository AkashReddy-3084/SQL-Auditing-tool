-- Checklist: Date/Time dimension exists with required attributes
-- Scope: DATABASE
-- Scoring: 2 = one or more date-dimension candidates exist; 0 = no date-dimension candidate. Required attributes and dimensional completeness require human review.
-- NOTE: Automated evidence only; required attributes and dimensional completeness require human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Date dimension metadata could not be evaluated';
DECLARE @DateDimensions INT = 0;

BEGIN TRY
    SELECT @DateDimensions = COUNT(*)
    FROM sys.tables
    WHERE name LIKE '%DimDate%' OR name LIKE '%Date_Dim%' OR name LIKE '%Calendar%' OR name LIKE 'Dim%Date%';

    SET @Score = CASE WHEN @DateDimensions > 0 THEN 2 ELSE 0 END;
    SET @Finding = N'date_dims=' + CONVERT(NVARCHAR(20), @DateDimensions);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read date dimension metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;