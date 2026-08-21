/*==============================================================================
  Checklist Item : 4.4.5 - tempdb configured appropriately (multiple files, sizing)
  Platform       : SQL Server (on-premises / IaaS) and Azure SQL Managed Instance
  Scope          : SERVER
  Access         : READ-ONLY. Catalog views and DMVs only. No DDL, DML, or
                   configuration change of any kind.
  Permissions    : VIEW ANY DEFINITION (sys.master_files),
                   VIEW SERVER STATE (sys.dm_os_sys_info - optional, degrades
                   gracefully if not granted).
==============================================================================*/
SET NOCOUNT ON;

DECLARE @EngineEdition    int            = CAST(SERVERPROPERTY('EngineEdition') AS int);
DECLARE @Result           nvarchar(20);
DECLARE @Score            int            = 0;
DECLARE @DatabaseQueried  nvarchar(128)  = N'tempdb';
DECLARE @Finding          nvarchar(4000) = N'';
DECLARE @Issues           nvarchar(2000) = N'';
DECLARE @Context          nvarchar(1000) = N'';
DECLARE @DataFileCount    int;
DECLARE @LogFileCount     int;
DECLARE @DistinctSizes    int;
DECLARE @DistinctGrowth   int;
DECLARE @PctGrowthFiles   int;
DECLARE @NoGrowthFiles    int;
DECLARE @MinSizeMB        decimal(19,2);
DECLARE @MaxSizeMB        decimal(19,2);
DECLARE @TotalSizeMB      decimal(19,2);
DECLARE @CpuCount         int;
DECLARE @RecommendedFiles int;

/* EngineEdition: 5 = Azure SQL Database, 6 = Synapse dedicated pool, 11 = Synapse serverless.
   On those platforms tempdb is provisioned by the service and is neither configurable nor visible. */
IF @EngineEdition IN (5, 6, 11)
BEGIN
    SET @Score   = 0;
    SET @Finding = N'NOT APPLICABLE: EngineEdition ' + CAST(@EngineEdition AS nvarchar(10))
                 + N' detected (Azure SQL Database / Azure Synapse Analytics). tempdb is provisioned and managed by the platform; the number, size and autogrowth of tempdb files are not configurable and not exposed through sys.master_files. This checklist item applies to SQL Server and Azure SQL Managed Instance only.';
END
ELSE
BEGIN
    SELECT
        @DataFileCount  = COUNT(*),
        @DistinctSizes  = COUNT(DISTINCT mf.size),
        @DistinctGrowth = COUNT(DISTINCT (CAST(mf.is_percent_growth AS int) * 1000000) + mf.growth),
        @PctGrowthFiles = SUM(CASE WHEN mf.is_percent_growth = 1 THEN 1 ELSE 0 END),
        @NoGrowthFiles  = SUM(CASE WHEN mf.growth = 0 THEN 1 ELSE 0 END),
        @MinSizeMB      = MIN(CAST(mf.size AS decimal(19,2)) * 8.0 / 1024.0),
        @MaxSizeMB      = MAX(CAST(mf.size AS decimal(19,2)) * 8.0 / 1024.0),
        @TotalSizeMB    = SUM(CAST(mf.size AS decimal(19,2)) * 8.0 / 1024.0)
    FROM sys.master_files AS mf
    WHERE mf.database_id = 2
      AND mf.type_desc   = N'ROWS';

    SELECT @LogFileCount = COUNT(*)
    FROM sys.master_files AS mf
    WHERE mf.database_id = 2
      AND mf.type_desc   = N'LOG';

    BEGIN TRY
        SELECT @CpuCount = si.cpu_count FROM sys.dm_os_sys_info AS si;
    END TRY
    BEGIN CATCH
        SET @CpuCount = NULL;
    END CATCH;

    /* Microsoft guidance: one data file per logical CPU up to a maximum of eight. */
    SET @RecommendedFiles = CASE
                                WHEN @CpuCount IS NULL THEN 4
                                WHEN @CpuCount <= 8    THEN @CpuCount
                                ELSE 8
                            END;

    IF @DataFileCount IS NULL OR @DataFileCount = 0
    BEGIN
        SET @Score   = 0;
        SET @Finding = N'Unable to determine the tempdb file layout: sys.master_files returned no ROWS files for database_id 2. VIEW ANY DEFINITION permission is required to read tempdb file metadata; re-run this check with sufficient rights.';
    END
    ELSE
    BEGIN
        SET @Context = N'Observed: ' + CAST(@DataFileCount AS nvarchar(10)) + N' data file(s), '
                     + CAST(ISNULL(@LogFileCount, 0) AS nvarchar(10)) + N' log file(s); total data size '
                     + CAST(@TotalSizeMB AS nvarchar(20)) + N' MB; per-file size range '
                     + CAST(@MinSizeMB AS nvarchar(20)) + N' MB to ' + CAST(@MaxSizeMB AS nvarchar(20)) + N' MB; '
                     + CAST(@PctGrowthFiles AS nvarchar(10)) + N' file(s) on percentage growth; '
                     + CAST(@NoGrowthFiles AS nvarchar(10)) + N' file(s) with autogrowth disabled; logical CPUs '
                     + ISNULL(CAST(@CpuCount AS nvarchar(10)), N'unavailable') + N'; recommended data files '
                     + CAST(@RecommendedFiles AS nvarchar(10)) + N'.';

        IF @DataFileCount = 1
            SET @Issues = @Issues + N'tempdb has only a single data file, so allocation-page contention is not distributed (recommended: ' + CAST(@RecommendedFiles AS nvarchar(10)) + N' data files); ';
        ELSE IF @DataFileCount < @RecommendedFiles
            SET @Issues = @Issues + N'tempdb has ' + CAST(@DataFileCount AS nvarchar(10)) + N' data files, fewer than the recommended ' + CAST(@RecommendedFiles AS nvarchar(10)) + N'; ';

        IF @DistinctSizes > 1
            SET @Issues = @Issues + N'the data files are not equally sized (' + CAST(@MinSizeMB AS nvarchar(20)) + N' MB to ' + CAST(@MaxSizeMB AS nvarchar(20)) + N' MB), which defeats proportional fill; ';

        IF @PctGrowthFiles > 0
            SET @Issues = @Issues + CAST(@PctGrowthFiles AS nvarchar(10)) + N' data file(s) use percentage autogrowth instead of a fixed size in MB; ';

        IF @NoGrowthFiles > 0
            SET @Issues = @Issues + CAST(@NoGrowthFiles AS nvarchar(10)) + N' data file(s) have autogrowth disabled; ';

        IF @DistinctGrowth > 1
            SET @Issues = @Issues + N'autogrowth settings are not identical across all data files; ';

        IF @Issues = N''
        BEGIN
            SET @Score   = 3;
            SET @Finding = N'tempdb is configured in line with guidance: multiple, equally sized data files with identical fixed-MB autogrowth enabled on every file. ' + @Context;
        END
        ELSE
        BEGIN
            SET @Issues = LEFT(@Issues, LEN(@Issues) - 1) + N'.';

            IF @DataFileCount > 1 AND @DistinctSizes = 1
            BEGIN
                SET @Score   = 2;
                SET @Finding = N'tempdb has multiple, equally sized data files but the configuration is only partially compliant: ' + @Issues + N' ' + @Context;
            END
            ELSE
            BEGIN
                SET @Score   = 1;
                SET @Finding = N'tempdb file configuration does not meet guidance: ' + @Issues + N' ' + @Context;
            END
        END
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;