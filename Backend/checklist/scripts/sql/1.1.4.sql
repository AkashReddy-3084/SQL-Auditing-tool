SET NOCOUNT ON;

DECLARE @EngineEdition      int           = CAST(SERVERPROPERTY('EngineEdition') AS int);
DECLARE @ProductEdition     nvarchar(128) = CAST(SERVERPROPERTY('Edition') AS nvarchar(128));
DECLARE @CurrentDb          sysname       = DB_NAME();
DECLARE @DbEdition          nvarchar(128) = CAST(DATABASEPROPERTYEX(DB_NAME(), 'Edition') AS nvarchar(128));
DECLARE @ServiceObjective   nvarchar(128) = CAST(DATABASEPROPERTYEX(DB_NAME(), 'ServiceObjective') AS nvarchar(128));
DECLARE @CpuCount           int;

DECLARE @AvgCpu             decimal(9,2),
        @MaxCpu             decimal(9,2),
        @AvgDataIo          decimal(9,2),
        @MaxDataIo          decimal(9,2),
        @AvgLogWrite        decimal(9,2),
        @MaxLogWrite        decimal(9,2),
        @AvgMemory          decimal(9,2),
        @SampleCount        int = 0,
        @MinutesObserved    int = 0;

DECLARE @AvgUtil            decimal(9,2),
        @PeakUtil           decimal(9,2);

DECLARE @Result             nvarchar(50),
        @Score              int,
        @DatabaseQueried    nvarchar(max) = NULL,
        @Finding            nvarchar(4000);

DECLARE @sql                nvarchar(max),
        @params             nvarchar(max);

SELECT @CpuCount = cpu_count FROM sys.dm_os_sys_info;

/* Determine which user database(s) this DATABASE-scope check applies to. */
IF @EngineEdition = 5   /* Azure SQL Database: only the current database context is visible */
BEGIN
    IF @CurrentDb IS NOT NULL AND @CurrentDb <> N'master'
        SET @DatabaseQueried = @CurrentDb;
END
ELSE
BEGIN
    SELECT @DatabaseQueried = STUFF((
        SELECT N', ' + d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state_desc = N'ONLINE'
          AND d.is_read_only = 0
          AND d.source_database_id IS NULL
        ORDER BY d.name
        FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'');
END

IF @DatabaseQueried IS NULL OR LTRIM(RTRIM(@DatabaseQueried)) = N''
BEGIN
    SET @DatabaseQueried = N'None';
    SET @Finding = N'No database found to be queried';
    SET @Score = 0;
END
ELSE IF @EngineEdition = 5   /* Azure SQL Database */
BEGIN
    IF OBJECT_ID('sys.dm_db_resource_stats') IS NOT NULL
    BEGIN
        SET @sql = N'
SELECT @AvgCpuOut          = AVG(avg_cpu_percent),
       @MaxCpuOut          = MAX(avg_cpu_percent),
       @AvgDataIoOut       = AVG(avg_data_io_percent),
       @MaxDataIoOut       = MAX(avg_data_io_percent),
       @AvgLogWriteOut     = AVG(avg_log_write_percent),
       @MaxLogWriteOut     = MAX(avg_log_write_percent),
       @AvgMemoryOut       = AVG(avg_memory_usage_percent),
       @SampleCountOut     = COUNT(*),
       @MinutesObservedOut = ISNULL(DATEDIFF(minute, MIN(end_time), MAX(end_time)), 0)
FROM sys.dm_db_resource_stats;';

        SET @params = N'@AvgCpuOut decimal(9,2) OUTPUT, @MaxCpuOut decimal(9,2) OUTPUT,
                        @AvgDataIoOut decimal(9,2) OUTPUT, @MaxDataIoOut decimal(9,2) OUTPUT,
                        @AvgLogWriteOut decimal(9,2) OUTPUT, @MaxLogWriteOut decimal(9,2) OUTPUT,
                        @AvgMemoryOut decimal(9,2) OUTPUT, @SampleCountOut int OUTPUT,
                        @MinutesObservedOut int OUTPUT';

        EXEC sp_executesql @sql, @params,
             @AvgCpuOut          = @AvgCpu          OUTPUT,
             @MaxCpuOut          = @MaxCpu          OUTPUT,
             @AvgDataIoOut       = @AvgDataIo       OUTPUT,
             @MaxDataIoOut       = @MaxDataIo       OUTPUT,
             @AvgLogWriteOut     = @AvgLogWrite     OUTPUT,
             @MaxLogWriteOut     = @MaxLogWrite     OUTPUT,
             @AvgMemoryOut       = @AvgMemory       OUTPUT,
             @SampleCountOut     = @SampleCount     OUTPUT,
             @MinutesObservedOut = @MinutesObserved OUTPUT;
    END

    SELECT @AvgUtil  = MAX(v) FROM (VALUES (@AvgCpu), (@AvgDataIo), (@AvgLogWrite)) AS a(v);
    SELECT @PeakUtil = MAX(v) FROM (VALUES (@MaxCpu), (@MaxDataIo), (@MaxLogWrite)) AS p(v);

    IF ISNULL(@SampleCount, 0) = 0 OR @AvgUtil IS NULL OR @PeakUtil IS NULL
    BEGIN
        SET @Score = 0;
        SET @Finding = N'Azure SQL Database ''' + @DatabaseQueried + N''' is provisioned on service objective '''
            + ISNULL(@ServiceObjective, N'unknown') + N''' (edition: ' + ISNULL(@DbEdition, N'unknown')
            + N'), but sys.dm_db_resource_stats returned no samples, so workload fit could not be measured. '
            + N'The compute tier must be reviewed manually against the observed workload before it can be accepted as appropriate.';
    END
    ELSE IF @AvgUtil >= 75.00 OR @PeakUtil >= 90.00
    BEGIN
        SET @Score = 1;
        SET @Finding = N'Compute tier appears undersized for the workload. Database ''' + @DatabaseQueried
            + N''' runs on service objective ''' + ISNULL(@ServiceObjective, N'unknown') + N''' (edition: '
            + ISNULL(@DbEdition, N'unknown') + N'). Over the last ' + CAST(ISNULL(@MinutesObserved, 0) AS nvarchar(20))
            + N' minute(s) across ' + CAST(@SampleCount AS nvarchar(20)) + N' sample(s): avg CPU '
            + ISNULL(CAST(@AvgCpu AS nvarchar(20)), N'n/a') + N'% (max ' + ISNULL(CAST(@MaxCpu AS nvarchar(20)), N'n/a')
            + N'%), avg data IO ' + ISNULL(CAST(@AvgDataIo AS nvarchar(20)), N'n/a') + N'% (max '
            + ISNULL(CAST(@MaxDataIo AS nvarchar(20)), N'n/a') + N'%), avg log write '
            + ISNULL(CAST(@AvgLogWrite AS nvarchar(20)), N'n/a') + N'% (max '
            + ISNULL(CAST(@MaxLogWrite AS nvarchar(20)), N'n/a') + N'%). Peak utilisation reached '
            + CAST(@PeakUtil AS nvarchar(20)) + N'%, so the workload is at or near the tier limit and is likely to be throttled.';
    END
    ELSE IF @AvgUtil < 10.00 AND @PeakUtil < 30.00
    BEGIN
        SET @Score = 2;
        SET @Finding = N'Compute tier appears over-provisioned for the workload. Database ''' + @DatabaseQueried
            + N''' runs on service objective ''' + ISNULL(@ServiceObjective, N'unknown') + N''' (edition: '
            + ISNULL(@DbEdition, N'unknown') + N') yet peak utilisation over ' + CAST(ISNULL(@MinutesObserved, 0) AS nvarchar(20))
            + N' minute(s) was only ' + CAST(@PeakUtil AS nvarchar(20)) + N'% (avg CPU '
            + ISNULL(CAST(@AvgCpu AS nvarchar(20)), N'n/a') + N'%, avg data IO '
            + ISNULL(CAST(@AvgDataIo AS nvarchar(20)), N'n/a') + N'%, avg log write '
            + ISNULL(CAST(@AvgLogWrite AS nvarchar(20)), N'n/a') + N'%). The tier sustains the workload but is materially larger than the measured demand.';
    END
    ELSE IF ISNULL(@ServiceObjective, N'') LIKE N'Basic%' OR ISNULL(@ServiceObjective, N'') = N'S0'
    BEGIN
        SET @Score = 2;
        SET @Finding = N'Database ''' + @DatabaseQueried + N''' runs on entry-level service objective '''
            + @ServiceObjective + N''' (edition: ' + ISNULL(@DbEdition, N'unknown')
            + N'). Utilisation is within limits (avg ' + CAST(@AvgUtil AS nvarchar(20)) + N'%, peak '
            + CAST(@PeakUtil AS nvarchar(20)) + N'% over ' + CAST(ISNULL(@MinutesObserved, 0) AS nvarchar(20))
            + N' minute(s)), but Basic/S0 tiers offer no read scale-out, limited IOPS and reduced availability guarantees for a production workload.';
    END
    ELSE
    BEGIN
        SET @Score = 3;
        SET @Finding = N'Compute tier is sized appropriately for the observed workload. Database ''' + @DatabaseQueried
            + N''' runs on service objective ''' + ISNULL(@ServiceObjective, N'unknown') + N''' (edition: '
            + ISNULL(@DbEdition, N'unknown') + N'). Over ' + CAST(ISNULL(@MinutesObserved, 0) AS nvarchar(20))
            + N' minute(s) across ' + CAST(@SampleCount AS nvarchar(20)) + N' sample(s): avg CPU '
            + ISNULL(CAST(@AvgCpu AS nvarchar(20)), N'n/a') + N'% (max ' + ISNULL(CAST(@MaxCpu AS nvarchar(20)), N'n/a')
            + N'%), avg data IO ' + ISNULL(CAST(@AvgDataIo AS nvarchar(20)), N'n/a') + N'%, avg log write '
            + ISNULL(CAST(@AvgLogWrite AS nvarchar(20)), N'n/a') + N'%, avg memory '
            + ISNULL(CAST(@AvgMemory AS nvarchar(20)), N'n/a') + N'%. Peak utilisation ' + CAST(@PeakUtil AS nvarchar(20))
            + N'% leaves headroom without indicating over-provisioning.';
    END
END
ELSE IF @EngineEdition = 8   /* Azure SQL Managed Instance */
BEGIN
    SET @Score = 0;
    SET @Finding = N'Instance is Azure SQL Managed Instance (edition: ' + ISNULL(@ProductEdition, N'unknown')
        + N', ' + CAST(ISNULL(@CpuCount, 0) AS nvarchar(20)) + N' vCore(s)). Service tier (General Purpose vs Business Critical) '
        + N'and vCore sizing are instance-level properties that are not exposed per database, so tier appropriateness for database(s) '''
        + LEFT(@DatabaseQueried, 1000) + N''' could not be evidenced from this connection and must be confirmed against workload IOPS/latency requirements.';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = N'Engine is not Azure SQL Database (EngineEdition = ' + CAST(@EngineEdition AS nvarchar(20))
        + N', edition: ' + ISNULL(@ProductEdition, N'unknown') + N', ' + CAST(ISNULL(@CpuCount, 0) AS nvarchar(20))
        + N' logical CPU(s)). vCore/DTU service tiers are not exposed for this deployment, so compute sizing for database(s) '''
        + LEFT(@DatabaseQueried, 1000) + N''' could not be evidenced and must be reviewed manually against the workload''s CPU, memory and IO requirements.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result           AS Result,
       @Score            AS Score,
       @DatabaseQueried  AS DatabaseQueried,
       @Finding          AS Finding;