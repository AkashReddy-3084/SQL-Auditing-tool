-- Checklist: DTU/vCore utilization profiled (peak vs off-peak)
-- Scope: SERVER
-- Scoring: 3 = utilization history spans a full day or longer, or samples exist alongside a running collector/scheduled capture job; 2 = several hours of history, or a collector/capture job with no samples yet; 1 = only a short in-memory sample window; 0 = no utilization history available

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No resource-utilization history could be read from this instance';

DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Samples INT = 0;
DECLARE @SpanHours INT = 0;
DECLARE @Collectors INT = 0;
DECLARE @Jobs INT = 0;
DECLARE @Source NVARCHAR(60) = 'none';
DECLARE @Sql NVARCHAR(MAX);

IF @Edition = 5
BEGIN
    BEGIN TRY
        IF OBJECT_ID('sys.resource_stats') IS NOT NULL
        BEGIN
            SET @Source = 'sys.resource_stats';
            SET @Sql = N'SELECT @s = COUNT(*),
       @h = ISNULL(DATEDIFF(HOUR, MIN(start_time), MAX(start_time)), 0)
FROM sys.resource_stats;';
        END
        ELSE
        BEGIN
            SET @Source = 'sys.dm_db_resource_stats';
            SET @Sql = N'SELECT @s = COUNT(*),
       @h = ISNULL(DATEDIFF(HOUR, MIN(end_time), MAX(end_time)), 0)
FROM sys.dm_db_resource_stats;';
        END

        EXEC sp_executesql @Sql, N'@s INT OUTPUT, @h INT OUTPUT',
             @s = @Samples OUTPUT, @h = @SpanHours OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Samples = 0;
    END CATCH
END
ELSE
BEGIN
    BEGIN TRY
        SET @Source = 'sys.dm_os_ring_buffers';
        SET @Sql = N'SELECT @s = COUNT(*) FROM sys.dm_os_ring_buffers
WHERE ring_buffer_type = N''RING_BUFFER_SCHEDULER_MONITOR'';';
        EXEC sp_executesql @Sql, N'@s INT OUTPUT', @s = @Samples OUTPUT;
        SET @SpanHours = ISNULL(@Samples, 0) / 60;
    END TRY
    BEGIN CATCH
        SET @Samples = 0;
    END CATCH

    BEGIN TRY
        IF OBJECT_ID('msdb.dbo.syscollector_collection_sets') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT @c = COUNT(*) FROM msdb.dbo.syscollector_collection_sets
WHERE is_running = 1;';
            EXEC sp_executesql @Sql, N'@c INT OUTPUT', @c = @Collectors OUTPUT;
        END
    END TRY
    BEGIN CATCH
        SET @Collectors = 0;
    END CATCH

    BEGIN TRY
        IF OBJECT_ID('msdb.dbo.sysjobsteps') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT @j = COUNT(DISTINCT st.job_id)
FROM msdb.dbo.sysjobsteps AS st
INNER JOIN msdb.dbo.sysjobs AS j ON j.job_id = st.job_id
INNER JOIN msdb.dbo.sysjobschedules AS sc ON sc.job_id = j.job_id
WHERE j.enabled = 1
  AND (st.command LIKE N''%dm[_]os[_]performance[_]counters%''
       OR st.command LIKE N''%dm[_]os[_]ring[_]buffers%''
       OR st.command LIKE N''%dm[_]db[_]resource[_]stats%''
       OR st.command LIKE N''%cpu[_]utilization%'');';
            EXEC sp_executesql @Sql, N'@j INT OUTPUT', @j = @Jobs OUTPUT;
        END
    END TRY
    BEGIN CATCH
        SET @Jobs = 0;
    END CATCH
END

SET @Samples = ISNULL(@Samples, 0);
SET @SpanHours = ISNULL(@SpanHours, 0);
SET @Collectors = ISNULL(@Collectors, 0);
SET @Jobs = ISNULL(@Jobs, 0);

SET @Score = CASE
    WHEN @SpanHours >= 24 OR (@Samples > 0 AND (@Collectors > 0 OR @Jobs > 0)) THEN 3
    WHEN @SpanHours >= 4 OR @Collectors > 0 OR @Jobs > 0 THEN 2
    WHEN @Samples > 0 THEN 1
    ELSE 0 END;

SET @Finding = CONCAT('Utilization source ', @Source, ' returned ', @Samples,
                      ' sample(s) spanning ', @SpanHours,
                      ' hour(s); running data-collector sets = ', @Collectors,
                      '; scheduled utilization-capture Agent jobs = ', @Jobs);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
