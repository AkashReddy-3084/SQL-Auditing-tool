-- Checklist: Business/transformation logic encapsulated in stored procedures/functions (not ad-hoc scripts)
-- Scope: DATABASE
-- Scoring: 2 = procedures/functions provide meaningful encapsulation evidence; 1 = some user code exists; 0 = no user code objects. Full encapsulation requires human review.
-- NOTE: Automated evidence only; ad-hoc execution outside stored modules cannot be verified from metadata.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Code encapsulation metadata could not be evaluated';
DECLARE @CodeObjects INT = 0;
DECLARE @Procedures INT = 0;
DECLARE @Functions INT = 0;
DECLARE @TablesTotal INT = 0;

BEGIN TRY
    SELECT @CodeObjects = COUNT(*) FROM sys.objects WHERE type IN ('P', 'FN', 'IF', 'TF', 'V') AND is_ms_shipped = 0;
    SELECT @Procedures = COUNT(*) FROM sys.objects WHERE type = 'P' AND is_ms_shipped = 0;
    SELECT @Functions = COUNT(*) FROM sys.objects WHERE type IN ('FN', 'IF', 'TF') AND is_ms_shipped = 0;
    SELECT @TablesTotal = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0;

    SET @Score = CASE WHEN @Procedures + @Functions > 0 THEN 2
                      WHEN @CodeObjects > 0 THEN 1 ELSE 0 END;
    SET @Finding = N'code_objects=' + CONVERT(NVARCHAR(20), @CodeObjects) + N', procs=' + CONVERT(NVARCHAR(20), @Procedures) + N', functions=' + CONVERT(NVARCHAR(20), @Functions) + N', tables_total=' + CONVERT(NVARCHAR(20), @TablesTotal);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read code object metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;