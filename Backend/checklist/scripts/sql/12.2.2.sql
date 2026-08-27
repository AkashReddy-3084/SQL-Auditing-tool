-- Checklist: Right-sizing reviewed periodically (over-provisioned tiers reduced)
-- Scope: SERVER
-- Scoring: 2 = server memory and physical memory are observable for capacity review; 1 = partial capacity evidence; 0 = memory metadata unavailable
-- NOTE: Automated evidence only; periodic review and right-sizing decisions require human review.

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'Capacity metadata could not be evaluated';
DECLARE @MaxMemory BIGINT = 0;
DECLARE @PhysicalMemory BIGINT = 0;
DECLARE @Cpus INT = 0;
DECLARE @UptimeDays INT = 0;

BEGIN TRY
    SELECT @MaxMemory = ISNULL(MAX(CONVERT(BIGINT, value_in_use)), 0) FROM sys.configurations WHERE name = 'max server memory (MB)';
    SELECT @PhysicalMemory = ISNULL(MAX(total_physical_memory_kb / 1024), 0), @Cpus = ISNULL(MAX(cpu_count), 0), @UptimeDays = ISNULL(MAX(DATEDIFF(day, sqlserver_start_time, GETDATE())), 0) FROM sys.dm_os_sys_info;
    SET @Score = CASE WHEN @MaxMemory > 0 AND @PhysicalMemory > 0 THEN 2 WHEN @MaxMemory > 0 OR @PhysicalMemory > 0 THEN 1 ELSE 0 END;
    SET @Finding = N'max_mem_mb=' + CONVERT(NVARCHAR(30), @MaxMemory) + N', phys_mem_mb=' + CONVERT(NVARCHAR(30), @PhysicalMemory) + N', cpus=' + CONVERT(NVARCHAR(20), @Cpus) + N', uptime_days=' + CONVERT(NVARCHAR(20), @UptimeDays);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read capacity metadata: ' + ERROR_MESSAGE();
END CATCH;
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;