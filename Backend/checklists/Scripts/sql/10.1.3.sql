-- Checklist: Resource utilization trended over time
-- Scope: SERVER
-- Scoring: 3 = retained resource history exists (platform resource-stats rows or a running data collector); 2 = Query Store retention or a DMV-sampling Agent job; 1 = only live performance counters, no retention; 0 = no trending evidence

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No resource-utilization trending evidence found';
DECLARE @Engine INT = ISNULL(CONVERT(INT, SERVERPROPERTY('EngineEdition')), 0);
DECLARE @HistoryRows INT = 0;
DECLARE @HistoryView NVARCHAR(128) = 'none';
DECLARE @RunningCollectors INT = 0;
DECLARE @SamplingJobs INT = 0;
DECLARE @JobNames NVARCHAR(MAX) = 'none';
DECLARE @QueryStoreDbs INT = 0;
DECLARE @Counters INT = 0;
DECLARE @Sql NVARCHAR(MAX);

BEGIN TRY
    SET @Sql = NULL;
    IF OBJECT_ID('sys.server_resource_stats') IS NOT NULL
    BEGIN
        SET @HistoryView = 'sys.server_resource_stats';
        SET @Sql = N'SELECT @c = COUNT(*) FROM sys.server_resource_stats;';
    END
    ELSE IF OBJECT_ID('sys.resource_stats') IS NOT NULL
    BEGIN
        SET @HistoryView = 'sys.resource_stats';
        SET @Sql = N'SELECT @c = COUNT(*) FROM sys.resource_stats;';
    END

    IF @Sql IS NOT NULL
        EXEC sys.sp_executesql @Sql, N'@c INT OUTPUT', @c = @HistoryRows OUTPUT;
END TRY
BEGIN CATCH
    SET @HistoryRows = 0;
END CATCH;

BEGIN TRY
    SET @Sql = N'SELECT @c = COUNT(*) FROM sys.dm_os_performance_counters;';
    EXEC sys.sp_executesql @Sql, N'@c INT OUTPUT', @c = @Counters OUTPUT;
END TRY
BEGIN CATCH
    SET @Counters = 0;
END CATCH;

BEGIN TRY
    SET @Sql = N'SELECT @c = COUNT(*) FROM sys.databases WHERE is_query_store_on = 1 AND state = 0;';
    EXEC sys.sp_executesql @Sql, N'@c INT OUTPUT', @c = @QueryStoreDbs OUTPUT;
END TRY
BEGIN CATCH
    SET @QueryStoreDbs = 0;
END CATCH;

IF @Engine <> 5
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT @c = COUNT(*) FROM msdb.dbo.syscollector_collection_sets WHERE is_running = 1;';
        EXEC sys.sp_executesql @Sql, N'@c INT OUTPUT', @c = @RunningCollectors OUTPUT;
    END TRY
    BEGIN CATCH
        SET @RunningCollectors = 0;
    END CATCH;

    BEGIN TRY
        SET @Sql = N'SELECT @c = COUNT(*), @n = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX), name), '', ''), ''none'') FROM (SELECT DISTINCT j.name FROM msdb.dbo.sysjobs AS j JOIN msdb.dbo.sysjobsteps AS s ON s.job_id = j.job_id WHERE s.command LIKE ''%dm[_]os[_]%'' OR s.command LIKE ''%dm[_]db[_]resource[_]stats%'' OR s.command LIKE ''%dm[_]io[_]virtual[_]file[_]stats%'' OR s.command LIKE ''%perfmon%'') AS x;';
        EXEC sys.sp_executesql @Sql, N'@c INT OUTPUT, @n NVARCHAR(MAX) OUTPUT', @c = @SamplingJobs OUTPUT, @n = @JobNames OUTPUT;
    END TRY
    BEGIN CATCH
        SET @SamplingJobs = 0;
    END CATCH;
END

SET @HistoryRows = ISNULL(@HistoryRows, 0);
SET @RunningCollectors = ISNULL(@RunningCollectors, 0);
SET @SamplingJobs = ISNULL(@SamplingJobs, 0);
SET @QueryStoreDbs = ISNULL(@QueryStoreDbs, 0);
SET @Counters = ISNULL(@Counters, 0);
SET @JobNames = ISNULL(@JobNames, 'none');

SET @Score = CASE
    WHEN @HistoryRows > 0 OR @RunningCollectors > 0 THEN 3
    WHEN @SamplingJobs > 0 OR @QueryStoreDbs > 0 THEN 2
    WHEN @Counters > 0 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT('Retained platform resource history: ', @HistoryView, ' = ', @HistoryRows,
    ' row(s); running data collector sets = ', @RunningCollectors,
    '; SQL Agent jobs sampling resource DMVs = ', @SamplingJobs, ' [', @JobNames, ']',
    '; databases with Query Store enabled = ', @QueryStoreDbs,
    '; live performance counters exposed = ', @Counters,
    CASE WHEN @HistoryRows = 0 AND @RunningCollectors = 0 AND @SamplingJobs = 0 AND @QueryStoreDbs = 0
         THEN '. Nothing persists resource utilization for later trend analysis.' ELSE '.' END);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;