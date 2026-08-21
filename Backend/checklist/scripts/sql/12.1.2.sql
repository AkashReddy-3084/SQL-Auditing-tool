SET NOCOUNT ON;

DECLARE @EngineEdition   INT            = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @DatabaseQueried SYSNAME        = DB_NAME();
DECLARE @Result          NVARCHAR(30);
DECLARE @Score           INT            = 0;
DECLARE @Finding         NVARCHAR(4000) = N'';
DECLARE @Sql             NVARCHAR(MAX)  = NULL;
DECLARE @Source          NVARCHAR(200)  = N'';
DECLARE @ErrMsg          NVARCHAR(2000) = NULL;

IF OBJECT_ID('tempdb..#Util') IS NOT NULL DROP TABLE #Util;
CREATE TABLE #Util
(
    ScopeName        NVARCHAR(256) NULL,
    SampleCount      INT           NULL,
    FirstSample      DATETIME      NULL,
    LastSample       DATETIME      NULL,
    PeakSamples      INT           NULL,
    OffPeakSamples   INT           NULL,
    PeakAvgCpuPct    DECIMAL(9,2)  NULL,
    OffPeakAvgCpuPct DECIMAL(9,2)  NULL,
    PeakMaxCpuPct    DECIMAL(9,2)  NULL,
    OffPeakMaxCpuPct DECIMAL(9,2)  NULL
);

BEGIN TRY
    IF @EngineEdition = 5 AND DB_NAME() = N'master'
    BEGIN
        SET @Source = N'sys.resource_stats (master, up to 14 days of DTU/vCore history)';
        SET @Sql = N'
SELECT  rs.database_name,
        COUNT_BIG(*),
        MIN(rs.start_time),
        MAX(rs.start_time),
        SUM(CASE WHEN DATEPART(HOUR, rs.start_time) >= 8 AND DATEPART(HOUR, rs.start_time) < 20 THEN 1 ELSE 0 END),
        SUM(CASE WHEN DATEPART(HOUR, rs.start_time) >= 8 AND DATEPART(HOUR, rs.start_time) < 20 THEN 0 ELSE 1 END),
        CAST(AVG(CASE WHEN DATEPART(HOUR, rs.start_time) >= 8 AND DATEPART(HOUR, rs.start_time) < 20 THEN rs.avg_cpu_percent END) AS DECIMAL(9,2)),
        CAST(AVG(CASE WHEN DATEPART(HOUR, rs.start_time) >= 8 AND DATEPART(HOUR, rs.start_time) < 20 THEN NULL ELSE rs.avg_cpu_percent END) AS DECIMAL(9,2)),
        CAST(MAX(CASE WHEN DATEPART(HOUR, rs.start_time) >= 8 AND DATEPART(HOUR, rs.start_time) < 20 THEN rs.avg_cpu_percent END) AS DECIMAL(9,2)),
        CAST(MAX(CASE WHEN DATEPART(HOUR, rs.start_time) >= 8 AND DATEPART(HOUR, rs.start_time) < 20 THEN NULL ELSE rs.avg_cpu_percent END) AS DECIMAL(9,2))
FROM sys.resource_stats AS rs
WHERE rs.start_time >= DATEADD(DAY, -14, GETUTCDATE())
GROUP BY rs.database_name;';
    END
    ELSE IF @EngineEdition = 5
    BEGIN
        SET @Source = N'sys.dm_db_resource_stats (single database, approx. 1 hour of history)';
        SET @Sql = N'
SELECT  DB_NAME(),
        COUNT_BIG(*),
        MIN(rs.end_time),
        MAX(rs.end_time),
        SUM(CASE WHEN DATEPART(HOUR, rs.end_time) >= 8 AND DATEPART(HOUR, rs.end_time) < 20 THEN 1 ELSE 0 END),
        SUM(CASE WHEN DATEPART(HOUR, rs.end_time) >= 8 AND DATEPART(HOUR, rs.end_time) < 20 THEN 0 ELSE 1 END),
        CAST(AVG(CASE WHEN DATEPART(HOUR, rs.end_time) >= 8 AND DATEPART(HOUR, rs.end_time) < 20 THEN rs.avg_cpu_percent END) AS DECIMAL(9,2)),
        CAST(AVG(CASE WHEN DATEPART(HOUR, rs.end_time) >= 8 AND DATEPART(HOUR, rs.end_time) < 20 THEN NULL ELSE rs.avg_cpu_percent END) AS DECIMAL(9,2)),
        CAST(MAX(CASE WHEN DATEPART(HOUR, rs.end_time) >= 8 AND DATEPART(HOUR, rs.end_time) < 20 THEN rs.avg_cpu_percent END) AS DECIMAL(9,2)),
        CAST(MAX(CASE WHEN DATEPART(HOUR, rs.end_time) >= 8 AND DATEPART(HOUR, rs.end_time) < 20 THEN NULL ELSE rs.avg_cpu_percent END) AS DECIMAL(9,2))
FROM sys.dm_db_resource_stats AS rs;';
    END
    ELSE IF @EngineEdition = 8
    BEGIN
        SET @Source = N'sys.server_resource_stats (managed instance, up to 14 days of vCore history)';
        SET @Sql = N'
SELECT  CAST(SERVERPROPERTY(''ServerName'') AS NVARCHAR(256)),
        COUNT_BIG(*),
        MIN(rs.start_time),
        MAX(rs.start_time),
        SUM(CASE WHEN DATEPART(HOUR, rs.start_time) >= 8 AND DATEPART(HOUR, rs.start_time) < 20 THEN 1 ELSE 0 END),
        SUM(CASE WHEN DATEPART(HOUR, rs.start_time) >= 8 AND DATEPART(HOUR, rs.start_time) < 20 THEN 0 ELSE 1 END),
        CAST(AVG(CASE WHEN DATEPART(HOUR, rs.start_time) >= 8 AND DATEPART(HOUR, rs.start_time) < 20 THEN rs.avg_cpu_percent END) AS DECIMAL(9,2)),
        CAST(AVG(CASE WHEN DATEPART(HOUR, rs.start_time) >= 8 AND DATEPART(HOUR, rs.start_time) < 20 THEN NULL ELSE rs.avg_cpu_percent END) AS DECIMAL(9,2)),
        CAST(MAX(CASE WHEN DATEPART(HOUR, rs.start_time) >= 8 AND DATEPART(HOUR, rs.start_time) < 20 THEN rs.avg_cpu_percent END) AS DECIMAL(9,2)),
        CAST(MAX(CASE WHEN DATEPART(HOUR, rs.start_time) >= 8 AND DATEPART(HOUR, rs.start_time) < 20 THEN NULL ELSE rs.avg_cpu_percent END) AS DECIMAL(9,2))
FROM sys.server_resource_stats AS rs
WHERE rs.start_time >= DATEADD(DAY, -14, GETUTCDATE());';
    END

    IF @Sql IS NOT NULL
    BEGIN
        INSERT INTO #Util
        (
            ScopeName, SampleCount, FirstSample, LastSample,
            PeakSamples, OffPeakSamples,
            PeakAvgCpuPct, OffPeakAvgCpuPct, PeakMaxCpuPct, OffPeakMaxCpuPct
        )
        EXEC sp_executesql @Sql;
    END
END TRY
BEGIN CATCH
    SET @ErrMsg = ERROR_MESSAGE();
END CATCH;

DECLARE @Rows        INT    = (SELECT COUNT(*) FROM #Util);
DECLARE @Samples     BIGINT = (SELECT ISNULL(SUM(CAST(SampleCount AS BIGINT)), 0) FROM #Util);
DECLARE @SpanHours   INT    = (SELECT ISNULL(DATEDIFF(HOUR, MIN(FirstSample), MAX(LastSample)), 0) FROM #Util);
DECLARE @PeakRows    INT    = (SELECT COUNT(*) FROM #Util WHERE ISNULL(PeakSamples, 0) > 0);
DECLARE @OffPeakRows INT    = (SELECT COUNT(*) FROM #Util WHERE ISNULL(OffPeakSamples, 0) > 0);
DECLARE @TopList     NVARCHAR(2000) = NULL;

SELECT @TopList = STUFF((
    SELECT TOP (5)
           N'; ' + ISNULL(u.ScopeName, N'(unknown)')
         + N' peakAvgCpu=' + ISNULL(CONVERT(NVARCHAR(20), u.PeakAvgCpuPct), N'n/a') + N'%'
         + N' peakMaxCpu=' + ISNULL(CONVERT(NVARCHAR(20), u.PeakMaxCpuPct), N'n/a') + N'%'
         + N' offPeakAvgCpu=' + ISNULL(CONVERT(NVARCHAR(20), u.OffPeakAvgCpuPct), N'n/a') + N'%'
         + N' offPeakMaxCpu=' + ISNULL(CONVERT(NVARCHAR(20), u.OffPeakMaxCpuPct), N'n/a') + N'%'
    FROM #Util AS u
    ORDER BY ISNULL(u.PeakMaxCpuPct, 0) DESC
    FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

SET @TopList = LEFT(ISNULL(@TopList, N'none'), 1500);

IF @Sql IS NULL
BEGIN
    SET @Score = 1;
    SET @Finding = N'EngineEdition ' + CAST(@EngineEdition AS NVARCHAR(10))
                 + N' (non-Azure SQL Server) exposes no DTU or vCore utilization history; sys.resource_stats, sys.dm_db_resource_stats and sys.server_resource_stats are not available. '
                 + N'No peak vs off-peak utilization profile can be evidenced from the engine; profiling must come from an external monitoring platform (Performance Monitor captures, Azure Monitor / Log Analytics, or a third-party APM baseline).';
END
ELSE IF @ErrMsg IS NOT NULL
BEGIN
    SET @Score = 1;
    SET @Finding = N'Unable to read platform utilization telemetry from ' + @Source + N'. Error: ' + LEFT(@ErrMsg, 900)
                 + N'. The audit login most likely lacks VIEW DATABASE STATE / VIEW SERVER STATE, so peak vs off-peak DTU/vCore profiling could not be confirmed.';
END
ELSE IF @Samples = 0 OR @Rows = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'Utilization telemetry source ' + @Source + N' is readable but returned no samples for the retention window, so no DTU/vCore utilization profile (peak or off-peak) exists for this server.';
END
ELSE IF @SpanHours >= 168 AND @PeakRows > 0 AND @OffPeakRows > 0
BEGIN
    SET @Score = 3;
    SET @Finding = N'Utilization telemetry from ' + @Source + N' covers ' + CAST(@SpanHours AS NVARCHAR(20))
                 + N' hours (' + CAST(@Samples AS NVARCHAR(20)) + N' samples across ' + CAST(@Rows AS NVARCHAR(10))
                 + N' scope(s)) with samples in both the peak (08:00-19:59 UTC) and off-peak windows, so a peak vs off-peak DTU/vCore profile is derivable. Top scopes by peak CPU: ' + @TopList + N'.';
END
ELSE
BEGIN
    SET @Score = 2;
    SET @Finding = N'Utilization telemetry from ' + @Source + N' returned ' + CAST(@Samples AS NVARCHAR(20))
                 + N' sample(s) across ' + CAST(@Rows AS NVARCHAR(10)) + N' scope(s) spanning only ' + CAST(@SpanHours AS NVARCHAR(20))
                 + N' hours; peak-window scopes=' + CAST(@PeakRows AS NVARCHAR(10)) + N', off-peak-window scopes=' + CAST(@OffPeakRows AS NVARCHAR(10))
                 + N'. The history is short or covers only one window, so the peak vs off-peak profile is partial. Observed values: ' + @TopList + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;

IF OBJECT_ID('tempdb..#Util') IS NOT NULL DROP TABLE #Util;