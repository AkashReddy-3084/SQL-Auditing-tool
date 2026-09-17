/* Checklist 14.5.4 - Plan cache health reviewed (no excessive single-use plans / bloat)
   Strictly read-only: DMV / catalog view inspection only. */
SET NOCOUNT ON;

DECLARE @DatabaseQueried NVARCHAR(256) =
    CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) = 5
         THEN ISNULL(DB_NAME(), N'UnknownDatabase')
         ELSE ISNULL(CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(256)), CAST(@@SERVERNAME AS NVARCHAR(256)))
    END;

DECLARE @TotalPlans          BIGINT        = 0,
        @SingleUsePlans      BIGINT        = 0,
        @AdhocSingleUsePlans BIGINT        = 0,
        @TotalCacheMB        DECIMAL(18,2) = 0,
        @SingleUseCacheMB    DECIMAL(18,2) = 0,
        @SingleUsePlanPct    DECIMAL(9,2)  = 0,
        @SingleUseMemoryPct  DECIMAL(9,2)  = 0,
        @OptimizeForAdHoc    INT           = -1,
        @UptimeHours         DECIMAL(18,2) = -1,
        @AdHocText           NVARCHAR(100),
        @Result              NVARCHAR(20),
        @Score               INT,
        @Finding             NVARCHAR(4000);

/* Plan cache composition */
SELECT
    @TotalPlans          = ISNULL(COUNT_BIG(*), 0),
    @SingleUsePlans      = ISNULL(SUM(CASE WHEN cp.usecounts = 1 THEN 1 ELSE 0 END), 0),
    @AdhocSingleUsePlans = ISNULL(SUM(CASE WHEN cp.usecounts = 1 AND cp.objtype IN ('Adhoc', 'Prepared') THEN 1 ELSE 0 END), 0),
    @TotalCacheMB        = ISNULL(CAST(SUM(CAST(cp.size_in_bytes AS DECIMAL(38,2))) / 1048576.0 AS DECIMAL(18,2)), 0),
    @SingleUseCacheMB    = ISNULL(CAST(SUM(CASE WHEN cp.usecounts = 1 THEN CAST(cp.size_in_bytes AS DECIMAL(38,2)) ELSE 0 END) / 1048576.0 AS DECIMAL(18,2)), 0)
FROM sys.dm_exec_cached_plans AS cp;

/* Mitigation setting: 'optimize for ad hoc workloads' (stays -1 when not exposed, e.g. Azure SQL Database) */
SELECT @OptimizeForAdHoc = CAST(c.value_in_use AS INT)
FROM sys.configurations AS c
WHERE c.name = N'optimize for ad hoc workloads';

/* Uptime context - a very recent restart explains a small / empty cache */
SELECT @UptimeHours = CAST(DATEDIFF(MINUTE, si.sqlserver_start_time, SYSDATETIME()) / 60.0 AS DECIMAL(18,2))
FROM sys.dm_os_sys_info AS si;

SET @AdHocText =
    CASE WHEN @OptimizeForAdHoc = -1 THEN N'not exposed on this engine edition'
         WHEN @OptimizeForAdHoc = 1 THEN N'1 (enabled)'
         ELSE N'0 (disabled)' END;

SET @SingleUsePlanPct =
    CASE WHEN @TotalPlans > 0
         THEN CAST(@SingleUsePlans * 100.0 / @TotalPlans AS DECIMAL(9,2))
         ELSE 0 END;

SET @SingleUseMemoryPct =
    CASE WHEN @TotalCacheMB > 0
         THEN CAST(@SingleUseCacheMB * 100.0 / @TotalCacheMB AS DECIMAL(9,2))
         ELSE 0 END;

IF @TotalPlans = 0
BEGIN
    SET @Score  = 2;
    SET @Finding = CONCAT(
        N'Plan cache is empty (0 cached plans); plan cache health cannot be assessed from current runtime state. Instance uptime: ',
        CAST(@UptimeHours AS NVARCHAR(20)), N' hour(s). ''optimize for ad hoc workloads'' = ', @AdHocText, N'.');
END
ELSE IF @SingleUseMemoryPct <= 20.0 AND @SingleUsePlanPct <= 50.0
BEGIN
    SET @Score  = 3;
    SET @Finding = CONCAT(
        N'Plan cache is healthy: ', CAST(@SingleUsePlans AS NVARCHAR(20)), N' of ', CAST(@TotalPlans AS NVARCHAR(20)),
        N' cached plans are single-use (', CAST(@SingleUsePlanPct AS NVARCHAR(20)), N'%), consuming ',
        CAST(@SingleUseCacheMB AS NVARCHAR(20)), N' MB of ', CAST(@TotalCacheMB AS NVARCHAR(20)), N' MB total cache (',
        CAST(@SingleUseMemoryPct AS NVARCHAR(20)), N'%). Single-use Adhoc/Prepared plans: ',
        CAST(@AdhocSingleUsePlans AS NVARCHAR(20)), N'. ''optimize for ad hoc workloads'' = ', @AdHocText,
        N'. Instance uptime: ', CAST(@UptimeHours AS NVARCHAR(20)), N' hour(s).');
END
ELSE IF @SingleUseMemoryPct <= 40.0 OR (@OptimizeForAdHoc = 1 AND @SingleUseCacheMB <= 250.0)
BEGIN
    SET @Score  = 2;
    SET @Finding = CONCAT(
        N'Moderate plan cache bloat: ', CAST(@SingleUsePlans AS NVARCHAR(20)), N' of ', CAST(@TotalPlans AS NVARCHAR(20)),
        N' cached plans are single-use (', CAST(@SingleUsePlanPct AS NVARCHAR(20)), N'%), consuming ',
        CAST(@SingleUseCacheMB AS NVARCHAR(20)), N' MB of ', CAST(@TotalCacheMB AS NVARCHAR(20)), N' MB total cache (',
        CAST(@SingleUseMemoryPct AS NVARCHAR(20)), N'%). Single-use Adhoc/Prepared plans: ',
        CAST(@AdhocSingleUsePlans AS NVARCHAR(20)), N'. ''optimize for ad hoc workloads'' = ', @AdHocText,
        N'. Instance uptime: ', CAST(@UptimeHours AS NVARCHAR(20)), N' hour(s).');
END
ELSE
BEGIN
    SET @Score  = 1;
    SET @Finding = CONCAT(
        N'Excessive single-use plan bloat: ', CAST(@SingleUsePlans AS NVARCHAR(20)), N' of ', CAST(@TotalPlans AS NVARCHAR(20)),
        N' cached plans are single-use (', CAST(@SingleUsePlanPct AS NVARCHAR(20)), N'%), wasting ',
        CAST(@SingleUseCacheMB AS NVARCHAR(20)), N' MB of ', CAST(@TotalCacheMB AS NVARCHAR(20)), N' MB total cache (',
        CAST(@SingleUseMemoryPct AS NVARCHAR(20)), N'%). Single-use Adhoc/Prepared plans: ',
        CAST(@AdhocSingleUsePlans AS NVARCHAR(20)), N'. ''optimize for ad hoc workloads'' = ', @AdHocText,
        N'. Instance uptime: ', CAST(@UptimeHours AS NVARCHAR(20)), N' hour(s).');
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;