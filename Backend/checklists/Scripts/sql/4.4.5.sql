-- Checklist: [Partitioning & Storage] tempdb configured appropriately (multiple files, sizing) - SQL Server/MI
-- Scope: SERVER
-- Scoring: 3 = file count meets the CPU-based target with equal sizes, equal growth and no percentage growth; 2 = multiple equally-sized files but fewer than the target count or uneven growth, or Azure SQL Database platform-managed; 1 = a single data file, or percentage growth is configured; 0 = tempdb file metadata unavailable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'tempdb data file metadata could not be read';

DECLARE @IsAzureDb BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @ReadError BIT = 0;
DECLARE @DataFiles INT = 0;
DECLARE @DistinctSizes INT = 0;
DECLARE @DistinctGrowth INT = 0;
DECLARE @PercentGrowthFiles INT = 0;
DECLARE @SmallestMb INT = 0;
DECLARE @LargestMb INT = 0;
DECLARE @CpuCount INT = 0;
DECLARE @TargetFiles INT = 0;
DECLARE @FileNames NVARCHAR(MAX) = 'none';

IF @IsAzureDb = 0
BEGIN
    BEGIN TRY
        SELECT @DataFiles          = COUNT(*),
               @DistinctSizes      = COUNT(DISTINCT size),
               @DistinctGrowth     = COUNT(DISTINCT growth),
               @PercentGrowthFiles = ISNULL(SUM(CASE WHEN is_percent_growth = 1 THEN 1 ELSE 0 END), 0),
               @SmallestMb         = ISNULL(MIN(size) / 128, 0),
               @LargestMb          = ISNULL(MAX(size) / 128, 0)
        FROM sys.master_files
        WHERE database_id = 2
          AND type = 0;

        SET @FileNames = ISNULL(LEFT((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), name), ', ')
                                      FROM sys.master_files
                                      WHERE database_id = 2 AND type = 0), 600), 'none');

        SELECT @CpuCount = ISNULL(MAX(cpu_count), 0) FROM sys.dm_os_sys_info;
    END TRY
    BEGIN CATCH
        SET @ReadError = 1;
    END CATCH;
END

-- Microsoft guidance: one data file per logical CPU, capped at eight.
SET @TargetFiles = CASE WHEN @CpuCount BETWEEN 1 AND 8 THEN @CpuCount ELSE 8 END;

SET @Score = CASE
    WHEN @IsAzureDb = 1 THEN 2
    WHEN @ReadError = 1 OR @DataFiles = 0 THEN 0
    WHEN @DataFiles = 1 OR @PercentGrowthFiles > 0 THEN 1
    WHEN @DataFiles >= @TargetFiles AND @DistinctSizes = 1 AND @DistinctGrowth = 1 THEN 3
    WHEN @DistinctSizes = 1 THEN 2
    ELSE 1
END;

SET @Finding = CASE
    WHEN @IsAzureDb = 1
        THEN 'Azure SQL Database (EngineEdition 5): tempdb file count and sizing are provisioned and managed by the platform and are not exposed for configuration.'
    WHEN @ReadError = 1 OR @DataFiles = 0
        THEN 'tempdb data file metadata in sys.master_files could not be read, so file count and sizing were not verified.'
    ELSE CONCAT('tempdb data files = ', @DataFiles, ' (CPU-based target ', @TargetFiles,
                '); distinct file sizes = ', @DistinctSizes,
                ' (smallest ', @SmallestMb, ' MB, largest ', @LargestMb, ' MB)',
                '; distinct growth settings = ', @DistinctGrowth,
                '; files using percentage growth = ', @PercentGrowthFiles,
                '. Files: ', @FileNames, '.')
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;

