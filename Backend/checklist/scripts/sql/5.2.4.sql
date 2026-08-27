-- Checklist: Duplicate detection across batches
-- Scope: DATABASE
-- Scoring: 2 = uniqueness and deduplication evidence exists; 1 = one evidence source exists; 0 = no evidence
-- NOTE: Automated evidence only; cross-batch duplicate behavior requires data and workload review.

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = N'Duplicate-detection metadata could not be evaluated';
DECLARE @UniqueIndexes INT = 0;
DECLARE @TablesTotal INT = 0;
DECLARE @DedupModules INT = 0;

BEGIN TRY
    SELECT @UniqueIndexes = COUNT(*) FROM sys.indexes AS i JOIN sys.tables AS t ON t.object_id = i.object_id WHERE t.is_ms_shipped = 0 AND i.is_unique = 1;
    SELECT @TablesTotal = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0;
    SELECT @DedupModules = COUNT(*) FROM sys.sql_modules WHERE definition LIKE '%ROW_NUMBER%' OR definition LIKE '%HAVING%COUNT%';
    SET @Score = CASE WHEN @UniqueIndexes > 0 AND @DedupModules > 0 THEN 2 WHEN @UniqueIndexes > 0 OR @DedupModules > 0 THEN 1 ELSE 0 END;
    SET @Finding = N'unique_indexes=' + CONVERT(NVARCHAR(20), @UniqueIndexes) + N', tables_total=' + CONVERT(NVARCHAR(20), @TablesTotal) + N', dedup_modules=' + CONVERT(NVARCHAR(20), @DedupModules);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read duplicate-detection metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;