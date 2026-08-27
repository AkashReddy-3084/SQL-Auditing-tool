-- Checklist: Referential integrity validated (FKs in facts match dimensions)
-- Scope: DATABASE
-- Scoring: 2 = foreign keys exist and all are trusted; 1 = foreign keys exist but some are untrusted; 0 = no foreign keys or metadata unavailable
-- NOTE: Automated evidence only; confirming fact/dimension semantics requires human review.

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Foreign-key metadata could not be evaluated';
DECLARE @ForeignKeys INT = 0;
DECLARE @Untrusted INT = 0;

BEGIN TRY
    SELECT @ForeignKeys = COUNT(*), @Untrusted = ISNULL(SUM(CASE WHEN is_not_trusted = 1 THEN 1 ELSE 0 END), 0) FROM sys.foreign_keys;
    SET @Score = CASE WHEN @ForeignKeys = 0 THEN 0 WHEN @Untrusted = 0 THEN 2 ELSE 1 END;
    SET @Finding = N'fks=' + CONVERT(NVARCHAR(20), @ForeignKeys) + N', untrusted=' + CONVERT(NVARCHAR(20), @Untrusted);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read foreign-key metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;