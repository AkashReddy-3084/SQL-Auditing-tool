SET NOCOUNT ON;

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @IsAzureSqlDb BIT = CASE WHEN @EngineEdition = 5 THEN 1 ELSE 0 END;

DECLARE @Result NVARCHAR(20);
DECLARE @Score INT = 0;
DECLARE @Finding NVARCHAR(4000) = N'';
DECLARE @DatabaseQueried NVARCHAR(256) = N'master';

DECLARE @CollectorRunning INT = 0;
DECLARE @MonitorJobCount INT = 0;
DECLARE @MonitorJobList NVARCHAR(1000) = N'';
DECLARE @NoGrowthFiles INT = 0;
DECLARE @PercentGrowthFiles INT = 0;
DECLARE @NearMaxFiles INT = 0;
DECLARE @NearMaxList NVARCHAR(1000) = N'';
DECLARE @LowVolumeCount INT = 0;
DECLARE @LowVolumeList NVARCHAR(1000) = N'';
DECLARE @VolumeStatsAvailable BIT = 1;
DECLARE @MonitoringPresent BIT = 0;
DECLARE @CapacityRisks INT = 0;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #FileCapacity
(
    DatabaseName SYSNAME NOT NULL,
    LogicalName  SYSNAME NOT NULL,
    FileTypeDesc NVARCHAR(60) NULL,
    SizeMB       DECIMAL(18,2) NULL,
    MaxSizeMB    DECIMAL(18,2) NULL,
    PctOfMaxSize DECIMAL(9,2) NULL,
    GrowthValue  INT NULL,
    IsPercentGrowth BIT NULL
);

CREATE TABLE #MonitorJobs
(
    JobName SYSNAME NOT NULL
);

IF @IsAzureSqlDb = 1
BEGIN
    SET @DatabaseQueried = DB_NAME();

    INSERT INTO #FileCapacity (DatabaseName, LogicalName, FileTypeDesc, SizeMB, MaxSizeMB, PctOfMaxSize, GrowthValue, IsPercentGrowth)
    SELECT DB_NAME(),
           f.name,
           f.type_desc,
           CAST(f.size * 8.0 / 1024.0 AS DECIMAL(18,2)),
           CASE WHEN f.max_size > 0 THEN CAST(f.max_size * 8.0 / 1024.0 AS DECIMAL(18,2)) ELSE NULL END,
           CASE WHEN f.max_size > 0 THEN CAST(f.size * 100.0 / f.max_size AS DECIMAL(9,2)) ELSE NULL END,
           f.growth,
           f.is_percent_growth
    FROM sys.database_files AS f
    WHERE f.type IN (0, 1);

    SELECT @NearMaxFiles = COUNT(*)
    FROM #FileCapacity
    WHERE PctOfMaxSize IS NOT NULL AND PctOfMaxSize >= 90.0;

    SELECT @NearMaxList = @NearMaxList
                          + CASE WHEN @NearMaxList = N'' THEN N'' ELSE N', ' END
                          + LogicalName + N' (' + CAST(PctOfMaxSize AS NVARCHAR(20)) + N'% of max)'
    FROM #FileCapacity
    WHERE PctOfMaxSize IS NOT NULL AND PctOfMaxSize >= 90.0;

    IF @NearMaxFiles > 0
    BEGIN
        SET @Score = 1;
        SET @Finding = N'Azure SQL Database: ' + CAST(@NearMaxFiles AS NVARCHAR(10))
                     + N' file(s) have reached 90% or more of their configured maximum size ('
                     + @NearMaxList + N'). Storage headroom is not being managed and no growth monitoring evidence is obtainable from T-SQL.';
    END
    ELSE
    BEGIN
        SET @Score = 2;
        SET @Finding = N'Azure SQL Database: all data/log files are below 90% of their configured maximum size, so current storage sizing is adequate. Growth monitoring itself is a platform-side control (Azure Monitor storage-percent metrics and alert rules) that cannot be verified through T-SQL and should be confirmed in the Azure portal.';
    END
END
ELSE
BEGIN
    SET @DatabaseQueried = N'master, msdb (server-wide)';

    IF OBJECT_ID(N'msdb.dbo.syscollector_collection_sets', N'U') IS NOT NULL
       OR OBJECT_ID(N'msdb.dbo.syscollector_collection_sets', N'V') IS NOT NULL
    BEGIN
        BEGIN TRY
            SET @Sql = N'SELECT @cnt = COUNT(*)
                         FROM msdb.dbo.syscollector_collection_sets
                         WHERE name = N''Disk Usage'' AND is_running = 1;';
            EXEC sp_executesql @Sql, N'@cnt INT OUTPUT', @cnt = @CollectorRunning OUTPUT;
        END TRY
        BEGIN CATCH
            SET @CollectorRunning = 0;
        END CATCH
    END

    IF OBJECT_ID(N'msdb.dbo.sysjobs', N'U') IS NOT NULL
    BEGIN
        BEGIN TRY
            SET @Sql = N'SELECT DISTINCT j.name
                         FROM msdb.dbo.sysjobs AS j
                         INNER JOIN msdb.dbo.sysjobsteps AS s ON s.job_id = j.job_id
                         INNER JOIN msdb.dbo.sysjobschedules AS js ON js.job_id = j.job_id
                         INNER JOIN msdb.dbo.sysschedules AS sch ON sch.schedule_id = js.schedule_id AND sch.enabled = 1
                         WHERE j.enabled = 1
                           AND (   j.name LIKE N''%space%''
                                OR j.name LIKE N''%growth%''
                                OR j.name LIKE N''%capacity%''
                                OR j.name LIKE N''%disk%''
                                OR j.name LIKE N''%storage%''
                                OR j.name LIKE N''%file size%''
                                OR ISNULL(j.description, N'''') LIKE N''%space%''
                                OR ISNULL(j.description, N'''') LIKE N''%growth%''
                                OR ISNULL(j.description, N'''') LIKE N''%capacity%''
                                OR s.command LIKE N''%dm_os_volume_stats%''
                                OR s.command LIKE N''%master_files%''
                                OR s.command LIKE N''%dm_db_file_space_usage%''
                                OR s.command LIKE N''%sp_spaceused%'');';

            INSERT INTO #MonitorJobs (JobName)
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            DELETE FROM #MonitorJobs;
        END CATCH

        SELECT @MonitorJobCount = COUNT(*) FROM #MonitorJobs;

        SELECT @MonitorJobList = @MonitorJobList
                                 + CASE WHEN @MonitorJobList = N'' THEN N'' ELSE N', ' END
                                 + q.JobName
        FROM (SELECT TOP (5) JobName FROM #MonitorJobs ORDER BY JobName) AS q;
    END

    INSERT INTO #FileCapacity (DatabaseName, LogicalName, FileTypeDesc, SizeMB, MaxSizeMB, PctOfMaxSize, GrowthValue, IsPercentGrowth)
    SELECT d.name,
           mf.name,
           mf.type_desc,
           CAST(mf.size * 8.0 / 1024.0 AS DECIMAL(18,2)),
           CASE WHEN mf.max_size > 0 AND mf.max_size <> 268435456 THEN CAST(mf.max_size * 8.0 / 1024.0 AS DECIMAL(18,2)) ELSE NULL END,
           CASE WHEN mf.max_size > 0 AND mf.max_size <> 268435456 THEN CAST(mf.size * 100.0 / mf.max_size AS DECIMAL(9,2)) ELSE NULL END,
           mf.growth,
           mf.is_percent_growth
    FROM sys.master_files AS mf
    INNER JOIN sys.databases AS d ON d.database_id = mf.database_id
    WHERE mf.type IN (0, 1)
      AND mf.database_id <> 2
      AND d.state = 0
      AND d.source_database_id IS NULL;

    SELECT @NoGrowthFiles = ISNULL(SUM(CASE WHEN GrowthValue = 0 THEN 1 ELSE 0 END), 0),
           @PercentGrowthFiles = ISNULL(SUM(CASE WHEN IsPercentGrowth = 1 AND GrowthValue > 0 THEN 1 ELSE 0 END), 0),
           @NearMaxFiles = ISNULL(SUM(CASE WHEN PctOfMaxSize IS NOT NULL AND PctOfMaxSize >= 90.0 THEN 1 ELSE 0 END), 0)
    FROM #FileCapacity;

    SELECT @NearMaxList = @NearMaxList
                          + CASE WHEN @NearMaxList = N'' THEN N'' ELSE N', ' END
                          + DatabaseName + N'.' + LogicalName + N' (' + CAST(PctOfMaxSize AS NVARCHAR(20)) + N'% of max)'
    FROM #FileCapacity
    WHERE PctOfMaxSize IS NOT NULL AND PctOfMaxSize >= 90.0;

    BEGIN TRY
        SET @Sql = N'SELECT @cnt = COUNT(*)
                     FROM
                     (
                         SELECT DISTINCT vs.volume_mount_point AS MountPoint,
                                CAST(vs.available_bytes * 100.0 / NULLIF(vs.total_bytes, 0) AS DECIMAL(9,2)) AS PctFree
                         FROM sys.master_files AS mf
                         CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
                         WHERE vs.total_bytes > 0
                     ) AS v
                     WHERE v.PctFree < 15.0;

                     SELECT @list = @list
                                    + CASE WHEN @list = N'''' THEN N'''' ELSE N'', '' END
                                    + v.MountPoint + N'' ('' + CAST(v.PctFree AS NVARCHAR(20)) + N''% free)''
                     FROM
                     (
                         SELECT DISTINCT vs.volume_mount_point AS MountPoint,
                                CAST(vs.available_bytes * 100.0 / NULLIF(vs.total_bytes, 0) AS DECIMAL(9,2)) AS PctFree
                         FROM sys.master_files AS mf
                         CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
                         WHERE vs.total_bytes > 0
                     ) AS v
                     WHERE v.PctFree < 15.0;';

        EXEC sp_executesql @Sql,
             N'@cnt INT OUTPUT, @list NVARCHAR(1000) OUTPUT',
             @cnt = @LowVolumeCount OUTPUT,
             @list = @LowVolumeList OUTPUT;
    END TRY
    BEGIN CATCH
        SET @VolumeStatsAvailable = 0;
        SET @LowVolumeCount = 0;
        SET @LowVolumeList = N'';
    END CATCH

    SET @LowVolumeCount = ISNULL(@LowVolumeCount, 0);
    SET @LowVolumeList = ISNULL(@LowVolumeList, N'');

    SET @MonitoringPresent = CASE WHEN @CollectorRunning > 0 OR @MonitorJobCount > 0 THEN 1 ELSE 0 END;
    SET @CapacityRisks = @NearMaxFiles + @NoGrowthFiles + @LowVolumeCount;

    IF @MonitoringPresent = 1 AND @CapacityRisks = 0
        SET @Score = 3;
    ELSE IF @MonitoringPresent = 1 AND @CapacityRisks > 0
        SET @Score = 2;
    ELSE IF @MonitoringPresent = 0 AND @CapacityRisks = 0
        SET @Score = 1;
    ELSE
        SET @Score = 0;

    SET @Finding = N'Monitoring evidence: Data Collector "Disk Usage" collection set running = '
                 + CASE WHEN @CollectorRunning > 0 THEN N'YES' ELSE N'NO' END
                 + N'; enabled and scheduled SQL Agent space/growth jobs = ' + CAST(@MonitorJobCount AS NVARCHAR(10))
                 + CASE WHEN @MonitorJobList <> N'' THEN N' (' + @MonitorJobList + N')' ELSE N'' END
                 + N'. Capacity state: ' + CAST(@NearMaxFiles AS NVARCHAR(10)) + N' file(s) at >=90% of a hard MAXSIZE'
                 + CASE WHEN @NearMaxList <> N'' THEN N' [' + @NearMaxList + N']' ELSE N'' END
                 + N', ' + CAST(@NoGrowthFiles AS NVARCHAR(10)) + N' file(s) with autogrowth disabled, '
                 + CAST(@PercentGrowthFiles AS NVARCHAR(10)) + N' file(s) using percentage autogrowth, '
                 + CASE WHEN @VolumeStatsAvailable = 0
                        THEN N'volume free space could not be read (sys.dm_os_volume_stats unavailable or permission denied)'
                        ELSE CAST(@LowVolumeCount AS NVARCHAR(10)) + N' volume(s) below 15% free'
                             + CASE WHEN @LowVolumeList <> N'' THEN N' [' + @LowVolumeList + N']' ELSE N'' END
                   END
                 + N'.'
                 + CASE WHEN @MonitoringPresent = 0
                        THEN N' No in-instance storage sizing/growth monitoring mechanism was detected; an external monitoring platform, if used, must be evidenced separately.'
                        ELSE N'' END;
END

SET @Finding = LEFT(@Finding, 4000);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result,
       @Score AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding AS Finding;

DROP TABLE #FileCapacity;
DROP TABLE #MonitorJobs;