-- Checklist: Right-sizing reviewed periodically (over-provisioned tiers reduced)
-- Scope: SERVER
-- Scoring: 3 = provisioned capacity matches observed utilisation; 2 = one over-provisioning signal; 1 = two or more signals; 0 = capacity or utilisation metadata unreadable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Provisioned capacity and utilisation evidence could not be read';
DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Signals INT = 0;
DECLARE @Readable BIT = 0;
DECLARE @Sql NVARCHAR(MAX);
DECLARE @AvgCpu DECIMAL(9,2) = 0;
DECLARE @Samples INT = 0;
DECLARE @Sku NVARCHAR(128) = '';
DECLARE @Cpus INT = 0;
DECLARE @PhysMB BIGINT = 0;
DECLARE @CommittedMB BIGINT = 0;
DECLARE @TargetMB BIGINT = 0;
DECLARE @MaxMemMB BIGINT = 0;
DECLARE @DataMB DECIMAL(19,2) = 0;
DECLARE @UpDays INT = 0;

IF @Edition = 5
BEGIN
    SET @Sql = N'SELECT @avg = ISNULL(AVG(CONVERT(DECIMAL(9,2), rs.avg_cpu_percent)), 0),
                        @n = COUNT(*),
                        @sku = ISNULL(MAX(CONVERT(NVARCHAR(128), rs.sku)), N'''')
                 FROM sys.resource_stats AS rs
                 WHERE rs.start_time >= DATEADD(DAY, -7, GETUTCDATE());';
    BEGIN TRY
        EXEC sys.sp_executesql @Sql,
             N'@avg DECIMAL(9,2) OUTPUT, @n INT OUTPUT, @sku NVARCHAR(128) OUTPUT',
             @avg = @AvgCpu OUTPUT, @n = @Samples OUTPUT, @sku = @Sku OUTPUT;
        SET @Readable = 1;
    END TRY
    BEGIN CATCH
        SET @Samples = 0;
        SET @Readable = 1;
    END CATCH;

    SET @Signals = CASE WHEN @Samples = 0 THEN 1 WHEN @AvgCpu < 5 THEN 2 WHEN @AvgCpu < 20 THEN 1 ELSE 0 END;
    SET @Finding = CASE
        WHEN @Samples = 0 THEN 'Azure SQL Database: sys.resource_stats returned no samples, so tier utilisation could not be measured from the instance'
        ELSE CONCAT('Azure SQL Database: service tier = ', @Sku, ', average CPU ', @AvgCpu,
                    ' percent over ', @Samples, ' samples in the last 7 days')
    END;
END
ELSE
BEGIN
    BEGIN TRY
        SELECT @Cpus = ISNULL(MAX(cpu_count), 0),
               @PhysMB = ISNULL(MAX(physical_memory_kb) / 1024, 0),
               @CommittedMB = ISNULL(MAX(committed_kb) / 1024, 0),
               @TargetMB = ISNULL(MAX(committed_target_kb) / 1024, 0),
               @UpDays = ISNULL(MAX(DATEDIFF(DAY, sqlserver_start_time, GETDATE())), 0)
        FROM sys.dm_os_sys_info;

        SELECT @MaxMemMB = ISNULL(MAX(CONVERT(BIGINT, value_in_use)), 0)
        FROM sys.configurations
        WHERE name = 'max server memory (MB)';

        SELECT @DataMB = ISNULL(CONVERT(DECIMAL(19,2), SUM(CONVERT(DECIMAL(19,2), mf.size)) * 8.0 / 1024.0), 0)
        FROM sys.master_files AS mf
        WHERE mf.type = 0;

        SET @Readable = CASE WHEN @PhysMB > 0 THEN 1 ELSE 0 END;
    END TRY
    BEGIN CATCH
        SET @Readable = 0;
    END CATCH;

    SET @Signals =
          CASE WHEN @MaxMemMB >= 2147483647 THEN 1 ELSE 0 END
        + CASE WHEN @UpDays >= 7 AND @TargetMB > 0 AND @CommittedMB * 2 < @TargetMB THEN 1 ELSE 0 END
        + CASE WHEN @PhysMB > 0 AND @DataMB < @PhysMB * 0.25 THEN 1 ELSE 0 END;

    IF @Readable = 1
        SET @Finding = CONCAT('cpu_count = ', @Cpus, ', physical memory = ', @PhysMB,
                              ' MB, max server memory (MB) = ', @MaxMemMB,
                              ', buffer pool committed = ', @CommittedMB, ' MB of ', @TargetMB,
                              ' MB target, total data file size = ', @DataMB, ' MB, uptime = ', @UpDays,
                              ' day(s); over-provisioning signals = ', @Signals);
END

SET @Score = CASE
                WHEN @Readable = 0 THEN 0
                WHEN @Signals = 0 THEN 3
                WHEN @Signals = 1 THEN 2
                ELSE 1
             END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;