/*
    Checklist Item : 14.4.2 - tempdb contention monitored and mitigated
    Scope          : SERVER
    Description    : Read-only assessment of tempdb allocation-contention mitigation
                     (data file count, uniform sizing, uniform fixed growth, uniform
                     allocation behaviour) plus a point-in-time check for live
                     PAGELATCH waits on tempdb pages.
    Safety         : Strictly read-only. No DDL/DML against user or system objects.
                     A local temporary table is used only to capture DBCC TRACESTATUS output.
*/
SET NOCOUNT ON;

DECLARE @Result           NVARCHAR(50);
DECLARE @Score            INT            = 1;
DECLARE @DatabaseQueried  NVARCHAR(128)  = N'tempdb';
DECLARE @Finding          NVARCHAR(MAX)  = N'';

DECLARE @EngineEdition    INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @MajorVersion     INT = TRY_CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)), 4) AS INT);

IF @MajorVersion IS NULL
    SET @MajorVersion = 0;

IF @EngineEdition = 5
BEGIN
    /* Azure SQL Database - tempdb layout is fixed by the service objective and not queryable. */
    SET @Score = 2;
    SET @Finding = N'Azure SQL Database (EngineEdition 5) detected. tempdb file count, sizing, growth and allocation behaviour are managed by the platform and are not exposed through T-SQL, so contention mitigation cannot be verified by script. Confirm from monitoring tooling/documentation that tempdb PAGELATCH and resource-governance waits are tracked, and that the service objective provides sufficient tempdb throughput.';
END
ELSE
BEGIN
    DECLARE @CpuCount          INT = NULL;
    DECLARE @DataFileCount     INT = 0;
    DECLARE @DistinctSize      INT = 0;
    DECLARE @DistinctGrowth    INT = 0;
    DECLARE @PercentGrowthFile INT = 0;
    DECLARE @Recommended       INT = 8;
    DECLARE @TF1117            INT = 0;
    DECLARE @TF1118            INT = 0;
    DECLARE @MemOptTempdb      INT = 0;
    DECLARE @ContendedTasks    INT = 0;

    SELECT @CpuCount = cpu_count
    FROM sys.dm_os_sys_info;

    SELECT @DataFileCount     = COUNT(*),
           @DistinctSize      = COUNT(DISTINCT CAST(size AS BIGINT)),
           @DistinctGrowth    = COUNT(DISTINCT CAST(growth AS NVARCHAR(20)) + N'|' + CAST(is_percent_growth AS NVARCHAR(3))),
           @PercentGrowthFile = SUM(CASE WHEN is_percent_growth = 1 THEN 1 ELSE 0 END)
    FROM sys.master_files
    WHERE database_id = 2
      AND type = 0;

    /* TF 1117/1118 only matter before SQL Server 2016; DBCC TRACESTATUS is unsupported on Azure surfaces. */
    IF @MajorVersion > 0 AND @MajorVersion < 13 AND @EngineEdition IN (2, 3, 4)
    BEGIN
        CREATE TABLE #TraceStatus
        (
            TraceFlag INT NULL,
            [Status]  INT NULL,
            [Global]  INT NULL,
            [Session] INT NULL
        );

        BEGIN TRY
            INSERT INTO #TraceStatus (TraceFlag, [Status], [Global], [Session])
            EXEC ('DBCC TRACESTATUS(-1) WITH NO_INFOMSGS');

            SELECT @TF1117 = MAX(CASE WHEN TraceFlag = 1117 AND [Status] = 1 AND [Global] = 1 THEN 1 ELSE 0 END),
                   @TF1118 = MAX(CASE WHEN TraceFlag = 1118 AND [Status] = 1 AND [Global] = 1 THEN 1 ELSE 0 END)
            FROM #TraceStatus;
        END TRY
        BEGIN CATCH
            SET @TF1117 = 0;
            SET @TF1118 = 0;
        END CATCH

        IF OBJECT_ID('tempdb..#TraceStatus') IS NOT NULL
            DROP TABLE #TraceStatus;
    END

    IF @MajorVersion >= 15
        SET @MemOptTempdb = ISNULL(TRY_CAST(SERVERPROPERTY('IsTempdbMetadataMemoryOptimized') AS INT), 0);

    BEGIN TRY
        SELECT @ContendedTasks = COUNT(*)
        FROM sys.dm_os_waiting_tasks
        WHERE wait_type LIKE 'PAGELATCH%'
          AND resource_description LIKE '2:%';
    END TRY
    BEGIN CATCH
        SET @ContendedTasks = 0;
    END CATCH

    SET @Recommended = CASE
                          WHEN @CpuCount IS NULL THEN 8
                          WHEN @CpuCount < 8 THEN @CpuCount
                          ELSE 8
                       END;

    DECLARE @FileCountOk INT = CASE WHEN @DataFileCount >= @Recommended THEN 1 ELSE 0 END;
    DECLARE @SizeOk      INT = CASE WHEN @DataFileCount > 0 AND @DistinctSize = 1 THEN 1 ELSE 0 END;
    DECLARE @GrowthOk    INT = CASE WHEN @DataFileCount > 0 AND @PercentGrowthFile = 0 AND @DistinctGrowth = 1 THEN 1 ELSE 0 END;
    DECLARE @UniformOk   INT = CASE WHEN @MajorVersion >= 13 OR (@TF1117 = 1 AND @TF1118 = 1) THEN 1 ELSE 0 END;
    DECLARE @Passed      INT = @FileCountOk + @SizeOk + @GrowthOk + @UniformOk;

    IF @Passed = 4 AND @ContendedTasks = 0
        SET @Score = 3;
    ELSE IF @Passed >= 2
        SET @Score = 2;
    ELSE
        SET @Score = 1;

    SET @Finding =
          N'tempdb data files: ' + CAST(@DataFileCount AS NVARCHAR(10))
        + N' (recommended minimum ' + CAST(@Recommended AS NVARCHAR(10))
        + N' for ' + ISNULL(CAST(@CpuCount AS NVARCHAR(10)), N'unknown') + N' logical CPUs) - '
        + CASE WHEN @FileCountOk = 1 THEN N'OK' ELSE N'INSUFFICIENT' END
        + N'. Distinct file sizes: ' + CAST(@DistinctSize AS NVARCHAR(10))
        + N' - ' + CASE WHEN @SizeOk = 1 THEN N'uniformly sized' ELSE N'NOT uniformly sized' END
        + N'. Percent-growth data files: ' + CAST(ISNULL(@PercentGrowthFile, 0) AS NVARCHAR(10))
        + N', distinct growth settings: ' + CAST(@DistinctGrowth AS NVARCHAR(10))
        + N' - ' + CASE WHEN @GrowthOk = 1 THEN N'uniform fixed growth' ELSE N'NON-uniform or percent growth' END
        + N'. Uniform allocation: '
        + CASE WHEN @MajorVersion >= 13 THEN N'default behaviour on SQL Server 2016+ (major version ' + CAST(@MajorVersion AS NVARCHAR(10)) + N')'
               WHEN @UniformOk = 1 THEN N'trace flags 1117 and 1118 enabled globally'
               ELSE N'NOT guaranteed - trace flags 1117/1118 are not both enabled globally on this pre-2016 instance' END
        + N'. Memory-optimized tempdb metadata: ' + CASE WHEN @MemOptTempdb = 1 THEN N'enabled' ELSE N'not enabled/not applicable' END
        + N'. Live PAGELATCH waits on tempdb pages at execution time: ' + CAST(@ContendedTasks AS NVARCHAR(10))
        + N'. Mitigation conditions met: ' + CAST(@Passed AS NVARCHAR(10)) + N' of 4.'
        + N' Note: continuous monitoring of tempdb contention (alerting on PAGELATCH_UP/PAGELATCH_EX waits) cannot be verified from SQL Server metadata and must be confirmed against monitoring documentation.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;