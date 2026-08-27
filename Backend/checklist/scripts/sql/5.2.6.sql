-- Checklist: Corrupt/malformed rows isolated (not failing the entire batch)
-- Scope: DATABASE
-- Scoring: 2 = quarantine tables and isolating modules exist; 1 = one evidence source exists; 0 = no evidence
-- NOTE: Automated evidence only; proving malformed rows do not fail the batch requires operational review.

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Row-isolation metadata could not be evaluated';
DECLARE @QuarantineTables INT = 0;
DECLARE @IsolatingModules INT = 0;

BEGIN TRY
    SELECT @QuarantineTables = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0 AND (name LIKE '%error%' OR name LIKE '%reject%' OR name LIKE '%quarantine%' OR name LIKE '%exception%' OR name LIKE '%invalid%');
    SELECT @IsolatingModules = COUNT(*) FROM sys.sql_modules WHERE definition LIKE '%BEGIN%TRY%' AND (definition LIKE '%error%' OR definition LIKE '%reject%');
    SET @Score = CASE WHEN @QuarantineTables > 0 AND @IsolatingModules > 0 THEN 2 WHEN @QuarantineTables > 0 OR @IsolatingModules > 0 THEN 1 ELSE 0 END;
    SET @Finding = N'quarantine_tables=' + CONVERT(NVARCHAR(20), @QuarantineTables) + N', isolating_modules=' + CONVERT(NVARCHAR(20), @IsolatingModules);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read row-isolation metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;