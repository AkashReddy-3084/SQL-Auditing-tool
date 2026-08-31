-- Checklist: Source-to-target reconciliation exists for financial data
-- Scope: DATABASE
-- Scoring: 2 = reconciliation modules and tables exist; 1 = partial reconciliation evidence; 0 = no evidence
-- NOTE: Automated evidence only; financial scope and reconciliation correctness require human review.

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Reconciliation metadata could not be evaluated';
DECLARE @ReconModules INT = 0;
DECLARE @ReconTables INT = 0;
DECLARE @MoneyColumns INT = 0;

BEGIN TRY
    SELECT @ReconModules = COUNT(*) FROM sys.sql_modules AS m JOIN sys.objects AS o ON o.object_id = m.object_id
    WHERE (o.name LIKE '%recon%' OR o.name LIKE '%balance%') AND (m.definition LIKE '%SUM(%' OR m.definition LIKE '%COUNT(%');
    SELECT @ReconTables = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0 AND (name LIKE '%recon%' OR name LIKE '%control%' OR name LIKE '%balance%');
    SELECT @MoneyColumns = COUNT(*) FROM sys.columns AS c JOIN sys.tables AS t ON t.object_id = c.object_id JOIN sys.types AS ty ON ty.user_type_id = c.user_type_id WHERE t.is_ms_shipped = 0 AND ty.name IN ('money', 'smallmoney');
    SET @Score = CASE WHEN @ReconModules > 0 AND @ReconTables > 0 THEN 2 WHEN @ReconModules > 0 OR @ReconTables > 0 THEN 1 ELSE 0 END;
    SET @Finding = N'recon_modules=' + CONVERT(NVARCHAR(20), @ReconModules) + N', recon_tables=' + CONVERT(NVARCHAR(20), @ReconTables) + N', money_cols=' + CONVERT(NVARCHAR(20), @MoneyColumns);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read reconciliation metadata: ' + ERROR_MESSAGE();
END CATCH;
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;