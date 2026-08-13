-- Checklist: tempdb sized and file-configured correctly (SQL Server/MI)
-- Scope: SERVER
-- Scoring: 0=No data files or completely misconfigured; 1=Percentage growth, disabled growth, or initial size <100MB; 2=Fixed growth, growth>0, size>=100MB but file count doesn't match CPU cores; 3=Fully compliant (fixed growth, growth>0, size>=100MB, file count matches CPU cores capped at 8)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @CpuCount INT;
DECLARE @FileCount INT;
DECLARE @HasPercentGrowth BIT;
DECLARE @HasDisabledGrowth BIT;
DECLARE @MinInitialSizeMB INT;

-- Get logical CPU count
SELECT @CpuCount = @@CPU_COUNT;
IF @CpuCount IS NULL OR @CpuCount = 0 SET @CpuCount = 1;

-- Analyze tempdb data files (database_id = 2, type = 0)
SELECT
    @FileCount = COUNT(*),
    @HasPercentGrowth = MAX(CASE WHEN is_percent_growth = 1 THEN 1 ELSE 0 END),
    @HasDisabledGrowth = MAX(CASE WHEN growth = 0 THEN 1 ELSE 0 END),
    @MinInitialSizeMB = MIN(size * 8 / 1024)
FROM sys.master_files
WHERE database_id = 2 AND type = 0;

IF @FileCount = 0
BEGIN
    SET @Score = 0;
END
ELSE IF @HasPercentGrowth = 1 OR @HasDisabledGrowth = 1 OR @MinInitialSizeMB < 100
BEGIN
    SET @Score = 1;
END
ELSE
BEGIN
    -- Fixed growth, growth > 0, size >= 100MB
    DECLARE @TargetFileCount INT = CASE WHEN @CpuCount > 8 THEN 8 ELSE @CpuCount END;
    IF @FileCount = @TargetFileCount
        SET @Score = 3;
    ELSE
        SET @Score = 2;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;