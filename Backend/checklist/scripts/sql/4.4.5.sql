-- Checklist: tempdb configured appropriately (multiple files, sizing) - SQL Server/MI
-- Scope: SERVER
-- Scoring: 3 = multiple equally-sized tempdb data files; 2 = multiple tempdb data files but unequal sizes; 1 = only 1 tempdb data file; 0 = tempdb file information unavailable
-- NOTE: Automated evidence only; whether the file count matches CPU count for the workload requires human review.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'tempdb file information unavailable';

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database: tempdb file configuration is Microsoft-managed on this platform';
END
ELSE
BEGIN
    DECLARE @TempdbDataFileCount INT = 0, @DistinctSizeCount INT = 0;

    SELECT @TempdbDataFileCount = COUNT(*) FROM sys.master_files WHERE database_id = DB_ID('tempdb') AND type = 0;
    SELECT @DistinctSizeCount = COUNT(DISTINCT size) FROM sys.master_files WHERE database_id = DB_ID('tempdb') AND type = 0;

    SET @Score = CASE
        WHEN ISNULL(@TempdbDataFileCount,0) = 0 THEN 0
        WHEN @TempdbDataFileCount = 1 THEN 1
        WHEN @DistinctSizeCount = 1 THEN 3
        ELSE 2
    END;

    SET @Finding = CONCAT('tempdb data files = ', ISNULL(@TempdbDataFileCount,0), ', distinct file sizes = ', ISNULL(@DistinctSizeCount,0));
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;