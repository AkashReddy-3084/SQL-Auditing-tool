-- Checklist: Multi-step operations maintain integrity on partial failure
-- Scope: DATABASE
-- Scoring: 2 = transactional modules have TRY/CATCH rollback protection and savepoints; 1 = transactional modules exist without complete protection; 0 = no transactional modules or metadata unavailable
-- NOTE: Automated evidence only; runtime partial-failure behavior requires human review and testing.

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Transaction-integrity metadata could not be evaluated';
DECLARE @Modules INT = 0;
DECLARE @TransactionModules INT = 0;
DECLARE @ProtectedTransactionModules INT = 0;
DECLARE @SavepointModules INT = 0;

BEGIN TRY
    SELECT @Modules = COUNT(*) FROM sys.sql_modules;
    SELECT @TransactionModules = ISNULL(SUM(CASE WHEN m.definition LIKE '%BEGIN TRAN%' THEN 1 ELSE 0 END), 0),
           @ProtectedTransactionModules = ISNULL(SUM(CASE WHEN m.definition LIKE '%BEGIN TRAN%' AND m.definition LIKE '%BEGIN%TRY%' AND m.definition LIKE '%ROLLBACK%' THEN 1 ELSE 0 END), 0),
           @SavepointModules = ISNULL(SUM(CASE WHEN m.definition LIKE '%SAVE TRAN%' THEN 1 ELSE 0 END), 0)
    FROM sys.sql_modules AS m;

    SET @Score = CASE WHEN @TransactionModules = 0 THEN 0 WHEN @ProtectedTransactionModules = @TransactionModules AND @SavepointModules > 0 THEN 2 WHEN @ProtectedTransactionModules > 0 THEN 1 ELSE 1 END;
    SET @Finding = N'modules=' + CONVERT(NVARCHAR(20), @Modules) + N', tx_modules=' + CONVERT(NVARCHAR(20), @TransactionModules) + N', protected_tx_modules=' + CONVERT(NVARCHAR(20), @ProtectedTransactionModules) + N', savepoint_modules=' + CONVERT(NVARCHAR(20), @SavepointModules);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read transaction-integrity metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;