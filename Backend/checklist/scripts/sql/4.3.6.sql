-- Checklist: Missing-index recommendations reviewed (not blindly applied)
-- Scope: DATABASE
-- Scoring: 2 = no pending missing-index recommendations; 1 = recommendations exist and require review; 0 = metadata unavailable
-- NOTE: Automated evidence only; recommendation review and application decisions require human review.

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Missing-index metadata could not be evaluated';
DECLARE @Missing INT = 0;

BEGIN TRY
    SELECT @Missing = COUNT(*) FROM sys.dm_db_missing_index_details WHERE database_id = DB_ID();
    SET @Score = CASE WHEN @Missing = 0 THEN 2 ELSE 1 END;
    SET @Finding = N'missing=' + CONVERT(NVARCHAR(20), @Missing);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read missing-index metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;