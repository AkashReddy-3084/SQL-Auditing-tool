SET NOCOUNT ON;

DECLARE @EngineEdition       INT;
DECLARE @CpuCount            INT;
DECLARE @CpuUnknown          BIT;
DECLARE @RecommendedFiles    INT;
DECLARE @DataFileCount       INT;
DECLARE @LogFileCount        INT;
DECLARE @DistinctSizeCount   INT;
DECLARE @DistinctGrowthCount INT;
DECLARE @PercentGrowthFiles  INT;
DECLARE @NoGrowthFiles       INT;
DECLARE @MinDataSizeMB       DECIMAL(18,2);
DECLARE @MaxDataSizeMB       DECIMAL(18,2);
DECLARE @TotalDataSizeMB     DECIMAL(18,2);
DECLARE @FileCountOk         BIT;
DECLARE @SizeUniform         BIT;
DECLARE @GrowthUniform       BIT;
DECLARE @GrowthFixedMB       BIT;
DECLARE @GrowthEnabled       BIT;
DECLARE @SingleLogFile       BIT;
DECLARE @Deviations          NVARCHAR(2000);
DECLARE @Result              NVARCHAR(20);
DECLARE @Score               INT;
DECLARE @Finding             NVARCHAR(4000);

SET @EngineEdition = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition = 5
BEGIN
    SET @Score   = 3;
    SET @Finding = N'Azure SQL Database detected (EngineEdition 5). tempdb file count, file size and autogrowth are managed by the platform and cannot be configured by the customer, so this tempdb sizing and file configuration check does not apply to this deployment model.';
END
ELSE
BEGIN
    SET @CpuUnknown = 0;

    BEGIN TRY
        SELECT @CpuCount = si.cpu_count
        FROM sys.dm_os_sys_info AS si;
    END TRY
    BEGIN CATCH
        SET @CpuCount = NULL;
    END CATCH;

    IF @CpuCount IS NULL OR @CpuCount < 1
    BEGIN
        SET @CpuCount   = 4;
        SET @CpuUnknown = 1;
    END

    SET @RecommendedFiles = CASE WHEN @CpuCount >= 8 THEN 8 ELSE @CpuCount END;

    SELECT
        @DataFileCount      = SUM(CASE WHEN mf.type = 0 THEN 1 ELSE 0 END),
        @LogFileCount       = SUM(CASE WHEN mf.type = 1 THEN 1 ELSE 0 END),
        @PercentGrowthFiles = SUM(CASE WHEN mf.type = 0 AND mf.is_percent_growth = 1 THEN 1 ELSE 0 END),
        @NoGrowthFiles      = SUM(CASE WHEN mf.type = 0 AND mf.growth = 0 THEN 1 ELSE 0 END),
        @MinDataSizeMB      = MIN(CASE WHEN mf.type = 0 THEN CAST(mf.size AS DECIMAL(18,2)) * 8.0 / 1024.0 END),
        @MaxDataSizeMB      = MAX(CASE WHEN mf.type = 0 THEN CAST(mf.size AS DECIMAL(18,2)) * 8.0 / 1024.0 END),
        @TotalDataSizeMB    = SUM(CASE WHEN mf.type = 0 THEN CAST(mf.size AS DECIMAL(18,2)) * 8.0 / 1024.0 ELSE 0 END)
    FROM sys.master_files AS mf
    WHERE mf.database_id = 2;

    SELECT @DistinctSizeCount = COUNT(DISTINCT mf.size)
    FROM sys.master_files AS mf
    WHERE mf.database_id = 2
      AND mf.type = 0;

    SELECT @DistinctGrowthCount = COUNT(DISTINCT CAST(mf.growth AS NVARCHAR(20)) + N'|' + CAST(mf.is_percent_growth AS NVARCHAR(2)))
    FROM sys.master_files AS mf
    WHERE mf.database_id = 2
      AND mf.type = 0;

    IF @DataFileCount IS NULL OR @DataFileCount = 0
    BEGIN
        SET @Score   = 1;
        SET @Finding = N'tempdb file metadata could not be read from sys.master_files for database_id = 2. The audit login may lack VIEW ANY DEFINITION / VIEW SERVER STATE permission. Verify tempdb data file count, file sizes and autogrowth settings manually.';
    END
    ELSE
    BEGIN
        SET @FileCountOk   = CASE WHEN @DataFileCount >= @RecommendedFiles THEN 1 ELSE 0 END;
        SET @SizeUniform   = CASE WHEN @DistinctSizeCount <= 1 THEN 1 ELSE 0 END;
        SET @GrowthUniform = CASE WHEN @DistinctGrowthCount <= 1 THEN 1 ELSE 0 END;
        SET @GrowthFixedMB = CASE WHEN @PercentGrowthFiles = 0 THEN 1 ELSE 0 END;
        SET @GrowthEnabled = CASE WHEN @NoGrowthFiles = 0 THEN 1 ELSE 0 END;
        SET @SingleLogFile = CASE WHEN @LogFileCount = 1 THEN 1 ELSE 0 END;

        SET @Deviations = N'';

        IF @FileCountOk = 0
            SET @Deviations = @Deviations + N' Data file count (' + CAST(@DataFileCount AS NVARCHAR(10))
                            + N') is below the recommended ' + CAST(@RecommendedFiles AS NVARCHAR(10)) + N'.';

        IF @SizeUniform = 0
            SET @Deviations = @Deviations + N' Data files are not equally sized (min '
                            + CAST(@MinDataSizeMB AS NVARCHAR(30)) + N' MB, max '
                            + CAST(@MaxDataSizeMB AS NVARCHAR(30)) + N' MB).';

        IF @GrowthUniform = 0
            SET @Deviations = @Deviations + N' Data files do not share an identical autogrowth setting.';

        IF @GrowthFixedMB = 0
            SET @Deviations = @Deviations + N' ' + CAST(@PercentGrowthFiles AS NVARCHAR(10))
                            + N' data file(s) use percentage autogrowth instead of a fixed MB increment.';

        IF @GrowthEnabled = 0
            SET @Deviations = @Deviations + N' ' + CAST(@NoGrowthFiles AS NVARCHAR(10))
                            + N' data file(s) have autogrowth disabled (growth = 0).';

        IF @SingleLogFile = 0
            SET @Deviations = @Deviations + N' tempdb has ' + CAST(@LogFileCount AS NVARCHAR(10))
                            + N' log file(s); exactly one is expected.';

        IF @FileCountOk = 1 AND @SizeUniform = 1 AND @GrowthUniform = 1
           AND @GrowthFixedMB = 1 AND @GrowthEnabled = 1 AND @SingleLogFile = 1
            SET @Score = 3;
        ELSE IF @DataFileCount > 1
            SET @Score = 2;
        ELSE
            SET @Score = 1;

        SET @Finding = N'tempdb has ' + CAST(@DataFileCount AS NVARCHAR(10)) + N' data file(s) and '
                     + CAST(@LogFileCount AS NVARCHAR(10)) + N' log file(s). Recommended data files = '
                     + CAST(@RecommendedFiles AS NVARCHAR(10)) + N' based on min(logical CPUs = '
                     + CAST(@CpuCount AS NVARCHAR(10))
                     + CASE WHEN @CpuUnknown = 1 THEN N' [assumed; sys.dm_os_sys_info not readable]' ELSE N'' END
                     + N', 8). Configured data file size min/max/total = '
                     + CAST(@MinDataSizeMB AS NVARCHAR(30)) + N'/' + CAST(@MaxDataSizeMB AS NVARCHAR(30)) + N'/'
                     + CAST(@TotalDataSizeMB AS NVARCHAR(30)) + N' MB. Data files using percentage growth = '
                     + CAST(@PercentGrowthFiles AS NVARCHAR(10)) + N'; data files with autogrowth disabled = '
                     + CAST(@NoGrowthFiles AS NVARCHAR(10)) + N'; distinct size values = '
                     + CAST(@DistinctSizeCount AS NVARCHAR(10)) + N'; distinct growth settings = '
                     + CAST(@DistinctGrowthCount AS NVARCHAR(10)) + N'.'
                     + CASE WHEN LEN(@Deviations) > 0
                            THEN N' Deviations:' + @Deviations
                            ELSE N' All tempdb data files are equally sized with identical fixed-MB autogrowth, the file count meets the CPU-based guideline, and a single log file is present.'
                       END;
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result                          AS Result,
    @Score                           AS Score,
    CAST(N'tempdb' AS NVARCHAR(128)) AS DatabaseQueried,
    @Finding                         AS Finding;