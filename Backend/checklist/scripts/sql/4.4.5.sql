-- Checklist: tempdb configured appropriately (multiple files, sizing) - SQL Server/MI
-- Scope: SERVER
-- Scoring: 3 = multiple equally-sized files with consistent growth and no percentage growth; 2 = multiple files with one sizing or growth variance; 1 = one file or percentage growth is configured; 0 = tempdb evidence is unavailable
-- NOTE: Automated evidence covers tempdb file metadata; appropriate file count for workload and CPU requires human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'tempdb file evidence unavailable';
DECLARE @DataFileCount INT = 0;
DECLARE @DistinctSizeCount INT = 0;
DECLARE @DistinctGrowthCount INT = 0;
DECLARE @PercentGrowthFileCount INT = 0;
DECLARE @CpuCount INT = 0;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT
        @DataFileCount = COUNT(*),
        @DistinctSizeCount = COUNT(DISTINCT size),
        @DistinctGrowthCount = COUNT(DISTINCT growth),
        @PercentGrowthFileCount = ISNULL(SUM(CASE WHEN is_percent_growth = 1 THEN 1 ELSE 0 END), 0)
    FROM sys.master_files
    WHERE database_id = 2
      AND type = 0;

    SELECT @CpuCount = ISNULL(MAX(cpu_count), 0)
    FROM sys.dm_os_sys_info;
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

SET @Score = CASE
    WHEN @ReadError = 1 OR @DataFileCount = 0 THEN 0
    WHEN @DataFileCount > 1 AND @DistinctSizeCount = 1
         AND @DistinctGrowthCount = 1 AND @PercentGrowthFileCount = 0 THEN 3
    WHEN @DataFileCount > 1 AND @DistinctSizeCount = 1 THEN 2
    WHEN @DataFileCount > 1 OR @DistinctSizeCount = 1 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'tempdb data files = ', @DataFileCount,
    N'; distinct sizes = ', @DistinctSizeCount,
    N'; distinct growth values = ', @DistinctGrowthCount,
    N'; percentage-growth files = ', @PercentGrowthFileCount,
    N'; CPUs = ', @CpuCount,
    CASE WHEN @ReadError = 1 THEN N'; one or more server sources could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
