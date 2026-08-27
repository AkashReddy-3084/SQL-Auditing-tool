-- Checklist: Unique constraints on natural/business keys where appropriate
-- Scope: DATABASE
-- Scoring: 2 = user tables have unique non-primary-key indexes; 1 = no such indexes; 0 = metadata unavailable
-- NOTE: Automated evidence only; identifying appropriate natural/business keys requires human review.

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Unique-key metadata could not be evaluated';
DECLARE @Uniques INT = 0;

BEGIN TRY
    SELECT @Uniques = COUNT(*)
    FROM sys.indexes
    WHERE is_unique = 1 AND is_primary_key = 0
      AND OBJECTPROPERTY(object_id, 'IsUserTable') = 1;
    SET @Score = CASE WHEN @Uniques > 0 THEN 2 ELSE 1 END;
    SET @Finding = N'uniques=' + CONVERT(NVARCHAR(20), @Uniques);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read unique-key metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;