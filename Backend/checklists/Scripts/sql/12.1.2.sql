-- Checklist: DTU/vCore utilization profiled (peak vs off-peak)
-- Scope: SERVER
-- Scoring: 3 = CPU samples plus trend tables and collector jobs; 2 = any two utilization-history signals; 1 = one signal or uptime only; 0 = no queryable evidence
-- NOTE: Automated evidence only; these artifacts do not prove that peak and off-peak windows were compared by an operator.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'Utilization evidence unavailable';
DECLARE @CpuSampleCount INT = 0;
DECLARE @UptimeDays INT = 0;
DECLARE @TrendTableCount INT = 0;
DECLARE @CollectorJobCount INT = 0;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT @CpuSampleCount = COUNT(*)
    FROM sys.dm_os_ring_buffers
    WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR';
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

BEGIN TRY
    SELECT @UptimeDays = ISNULL(MAX(DATEDIFF(DAY, sqlserver_start_time, GETDATE())), 0)
    FROM sys.dm_os_sys_info;
END TRY
BEGIN CATCH
    SET @UptimeDays = 0;
END CATCH;

BEGIN TRY
    SELECT @TrendTableCount = COUNT(*)
    FROM sys.tables
    WHERE is_ms_shipped = 0
      AND (name LIKE N'%perf%' OR name LIKE N'%metric%'
           OR name LIKE N'%trend%' OR name LIKE N'%baseline%');
END TRY
BEGIN CATCH
    SET @TrendTableCount = 0;
END CATCH;

BEGIN TRY
    SELECT @CollectorJobCount = COUNT(*)
    FROM msdb.dbo.sysjobsteps
    WHERE command LIKE N'%dm[_]os%';
END TRY
BEGIN CATCH
    SET @CollectorJobCount = 0;
END CATCH;

SET @Score = CASE
    WHEN @CpuSampleCount > 0 AND @TrendTableCount > 0 AND @CollectorJobCount > 0 THEN 3
    WHEN (@CpuSampleCount > 0 AND @TrendTableCount > 0)
      OR (@CpuSampleCount > 0 AND @CollectorJobCount > 0)
      OR (@TrendTableCount > 0 AND @CollectorJobCount > 0) THEN 2
    WHEN @CpuSampleCount > 0 OR @TrendTableCount > 0 OR @CollectorJobCount > 0 OR @UptimeDays > 0 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'CPU scheduler-monitor samples = ', @CpuSampleCount,
    N'; uptime days = ', @UptimeDays,
    N'; trend tables = ', @TrendTableCount,
    N'; collector jobs = ', @CollectorJobCount,
    CASE WHEN @ReadError = 1 THEN N'; one or more DMV sources could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
