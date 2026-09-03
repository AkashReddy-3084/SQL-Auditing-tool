-- Checklist: tempdb sized and file-configured correctly (SQL Server/MI)
-- Scope: SERVER
-- Scoring: 3 = no deviation from the tempdb file guideline; 2 = one deviation, or Azure SQL Database where tempdb is managed by the platform; 1 = two or three deviations; 0 = four or more deviations, or tempdb file metadata could not be read

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'tempdb file configuration could not be read';
DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Cpu INT = 0;
DECLARE @Recommended INT = 0;
DECLARE @DataFiles INT = 0;
DECLARE @LogFiles INT = 0;
DECLARE @DistinctSizes INT = 0;
DECLARE @PercentGrowth INT = 0;
DECLARE @NoGrowth INT = 0;
DECLARE @MinMB DECIMAL(18, 2) = 0;
DECLARE @MaxMB DECIMAL(18, 2) = 0;
DECLARE @TotalMB DECIMAL(18, 2) = 0;
DECLARE @Deviations INT = 0;
DECLARE @Detail NVARCHAR(MAX) = '';
DECLARE @Read BIT = 0;

IF @Edition <> 5
BEGIN
    BEGIN TRY
        SELECT @Cpu = ISNULL(MAX(cpu_count), 0) FROM sys.dm_os_sys_info;

        SELECT @DataFiles = ISNULL(SUM(CASE WHEN mf.type = 0 THEN 1 ELSE 0 END), 0),
               @LogFiles = ISNULL(SUM(CASE WHEN mf.type = 1 THEN 1 ELSE 0 END), 0),
               @PercentGrowth = ISNULL(SUM(CASE WHEN mf.type = 0 AND mf.is_percent_growth = 1 THEN 1 ELSE 0 END), 0),
               @NoGrowth = ISNULL(SUM(CASE WHEN mf.type = 0 AND mf.growth = 0 THEN 1 ELSE 0 END), 0),
               @MinMB = ISNULL(MIN(CASE WHEN mf.type = 0 THEN CONVERT(DECIMAL(18, 2), mf.size) * 8.0 / 1024.0 END), 0),
               @MaxMB = ISNULL(MAX(CASE WHEN mf.type = 0 THEN CONVERT(DECIMAL(18, 2), mf.size) * 8.0 / 1024.0 END), 0),
               @TotalMB = ISNULL(SUM(CASE WHEN mf.type = 0 THEN CONVERT(DECIMAL(18, 2), mf.size) * 8.0 / 1024.0 ELSE 0 END), 0)
        FROM sys.master_files AS mf
        WHERE mf.database_id = 2;

        SELECT @DistinctSizes = ISNULL(COUNT(DISTINCT mf.size), 0)
        FROM sys.master_files AS mf
        WHERE mf.database_id = 2 AND mf.type = 0;

        SET @Read = CASE WHEN @DataFiles > 0 THEN 1 ELSE 0 END;
    END TRY
    BEGIN CATCH
        SET @Read = 0;
    END CATCH;
END

SET @Recommended = CASE WHEN @Cpu >= 8 THEN 8 WHEN @Cpu >= 1 THEN @Cpu ELSE 4 END;

IF @Read = 1
BEGIN
    IF @DataFiles < @Recommended
        SET @Detail = CONCAT(@Detail, 'data file count ', @DataFiles, ' is below the recommended ', @Recommended, '; ');
    IF @DistinctSizes > 1
        SET @Detail = CONCAT(@Detail, 'data files are unequally sized (', @MinMB, ' MB to ', @MaxMB, ' MB); ');
    IF @PercentGrowth > 0
        SET @Detail = CONCAT(@Detail, @PercentGrowth, ' data file(s) use percentage autogrowth; ');
    IF @NoGrowth > 0
        SET @Detail = CONCAT(@Detail, @NoGrowth, ' data file(s) have autogrowth disabled; ');
    IF @LogFiles <> 1
        SET @Detail = CONCAT(@Detail, 'tempdb has ', @LogFiles, ' log file(s) instead of exactly one; ');

    SET @Deviations =
        CASE WHEN @DataFiles < @Recommended THEN 1 ELSE 0 END +
        CASE WHEN @DistinctSizes > 1 THEN 1 ELSE 0 END +
        CASE WHEN @PercentGrowth > 0 THEN 1 ELSE 0 END +
        CASE WHEN @NoGrowth > 0 THEN 1 ELSE 0 END +
        CASE WHEN @LogFiles <> 1 THEN 1 ELSE 0 END;
END

SET @Score = CASE
    WHEN @Edition = 5 THEN 2
    WHEN @Read = 0 THEN 0
    WHEN @Deviations = 0 THEN 3
    WHEN @Deviations = 1 THEN 2
    WHEN @Deviations <= 3 THEN 1
    ELSE 0
END;

SET @Finding = CASE
    WHEN @Edition = 5
        THEN 'Azure SQL Database: tempdb file count, file size and autogrowth are managed by the platform and are not customer configurable'
    WHEN @Read = 0
        THEN 'tempdb file metadata for database_id = 2 could not be read from sys.master_files; the audit login may lack VIEW SERVER STATE'
    ELSE CONCAT(
        'tempdb has ', @DataFiles, ' data file(s) and ', @LogFiles, ' log file(s); recommended data files = ', @Recommended,
        ' (logical CPUs = ', @Cpu, ', capped at 8); data file size min/max/total = ', @MinMB, '/', @MaxMB, '/', @TotalMB, ' MB',
        '; distinct data file sizes = ', @DistinctSizes,
        '; percentage-growth files = ', @PercentGrowth,
        '; files with growth disabled = ', @NoGrowth,
        '; deviations = ', @Deviations,
        CASE WHEN @Deviations = 0 THEN ' (none)' ELSE CONCAT(': ', @Detail) END)
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
