-- Checklist: tempdb sized and file-configured correctly (SQL Server/MI)
-- Scope: SERVER
-- Scoring: 3: Fully compliant (uniform sizes, fixed MB auto-growth, appropriate file count). 2: Minor gaps (file count/size slightly off from ideal). 1: Partial (percentage/unlimited growth or single file on multi-core). 0: Non-compliant (zero size, severe misconfig, or missing files).

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @CpuCount INT;

SET @DatabaseQueried = 'master';

IF @EngineEdition = 5
BEGIN
    SET @Score = 3;
    SET @Finding = 'Not applicable for Azure SQL Database. tempdb is managed by the platform.';
END
ELSE
BEGIN
    SELECT @CpuCount = cpu_count FROM sys.dm_os_sys_info;

    DECLARE @Files TABLE (
        FileName NVARCHAR(128),
        FileType NVARCHAR(60),
        SizeMB DECIMAL(10,2),
        GrowthValue INT,
        IsPercent BIT
    );

    INSERT INTO @Files
    SELECT 
        name,
        type_desc,
        CAST(size AS DECIMAL(10,2)) / 128.0,
        growth,
        is_percent_growth
    FROM sys.master_files
    WHERE database_id = 2;

    DECLARE @DataFileCount INT = (SELECT COUNT(*) FROM @Files WHERE FileType = 'ROWS');
    DECLARE @LogCount INT = (SELECT COUNT(*) FROM @Files WHERE FileType = 'LOG');
    DECLARE @SameSize BIT = 1;
    DECLARE @DataFixedGrowth BIT = 1;
    DECLARE @LogFixedGrowth BIT = 1;
    DECLARE @Issues NVARCHAR(MAX) = '';

    IF (SELECT COUNT(DISTINCT SizeMB) FROM @Files WHERE FileType = 'ROWS') > 1 SET @SameSize = 0;
    IF EXISTS (SELECT 1 FROM @Files WHERE FileType = 'ROWS' AND (IsPercent = 1 OR GrowthValue = 0)) SET @DataFixedGrowth = 0;
    IF EXISTS (SELECT 1 FROM @Files WHERE FileType = 'LOG' AND (IsPercent = 1 OR GrowthValue = 0)) SET @LogFixedGrowth = 0;

    DECLARE @IdealCount INT = CASE WHEN @CpuCount > 8 THEN 8 ELSE @CpuCount END;
    IF @DataFileCount <> @IdealCount AND @DataFileCount <> 1 SET @Issues = @Issues + 'Data file count (' + CAST(@DataFileCount AS NVARCHAR) + ') does not match CPU cores (' + CAST(@IdealCount AS NVARCHAR) + '). ';
    IF @DataFileCount = 1 AND @CpuCount > 1 SET @Issues = @Issues + 'Single data file on multi-core server (' + CAST(@CpuCount AS NVARCHAR) + ' cores). ';
    IF @DataFixedGrowth = 0 SET @Issues = @Issues + 'Data files use percentage or unlimited growth. ';
    IF @LogFixedGrowth = 0 SET @Issues = @Issues + 'Log file uses percentage or unlimited growth. ';
    IF @SameSize = 0 SET @Issues = @Issues + 'Data files have varying sizes. ';

    SET @Score = 3;
    IF @DataFixedGrowth = 0 OR @LogFixedGrowth = 0 SET @Score = 1;
    ELSE IF @SameSize = 0 SET @Score = 2;
    ELSE IF @DataFileCount <> @IdealCount AND @DataFileCount <> 1 SET @Score = 2;
    ELSE IF @DataFileCount = 1 AND @CpuCount > 1 SET @Score = 2;

    DECLARE @FileDetails NVARCHAR(MAX);
    SELECT @FileDetails = STRING_AGG(FileName + ' (' + FileType + ', ' + CAST(SizeMB AS NVARCHAR) + 'MB, Growth: ' + CASE WHEN IsPercent=1 THEN CAST(GrowthValue AS NVARCHAR) + '%' ELSE CAST(GrowthValue AS NVARCHAR) + 'MB' END + ')', ', ')
    FROM @Files;

    SET @Finding = 'tempdb files: ' + @FileDetails + '. ' + ISNULL(NULLIF(@Issues, ''), 'Configuration meets best practices.');
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;