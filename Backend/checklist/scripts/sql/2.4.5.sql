/* Checklist 2.4.5 - ETL execution times monitored and baselined.
   Read-only, SERVER scope. Cross-database probes use dynamic SQL so that a
   missing msdb/SSISDB degrades to a finding instead of a binding error. */
SET NOCOUNT ON;

DECLARE @Result NVARCHAR(50) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(4000) = 'No database found to be queried';
DECLARE @Finding NVARCHAR(MAX) = 'No evidence was collected.';

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @DbList NVARCHAR(4000) = ISNULL(DB_NAME(), 'master');
DECLARE @BaselineDbs NVARCHAR(4000) = '';
DECLARE @Notes NVARCHAR(2000) = '';
DECLARE @Outcome NVARCHAR(1000) = '';

DECLARE @MsdbOnline BIT = 0;
DECLARE @SsisdbOnline BIT = 0;
DECLARE @EtlJobCount INT = 0;
DECLARE @EtlJobsWithHistory INT = 0;
DECLARE @EtlJobsWithTrend INT = 0;
DECLARE @EtlJobsNotified INT = 0;
DECLARE @DurationAlerts INT = 0;
DECLARE @SsisExecCount INT = 0;
DECLARE @SsisExecWithDuration INT = 0;
DECLARE @SsisRetentionDays INT = 0;
DECLARE @SsisLoggingLevel INT = -1;
DECLARE @BaselineObjects INT = 0;

DECLARE @HistoryEvidence BIT = 0;
DECLARE @BaselineEvidence BIT = 0;
DECLARE @MonitorEvidence BIT = 0;
DECLARE @AnyEtl BIT = 0;

DECLARE @sql NVARCHAR(MAX);
DECLARE @db SYSNAME = N'';
DECLARE @cnt INT = 0;

IF @EngineEdition = 5
BEGIN
    SET @Score = 0;
    SET @DatabaseQueried = ISNULL(DB_NAME(), 'No database found to be queried');
    SET @Finding = N'Azure SQL Database detected: SQL Server Agent (msdb), the SSIS catalog (SSISDB) and cross-database job history are not exposed to this engine, so no ETL run-duration history or baseline artifact can be evidenced from the database engine. Monitoring and baselining of ETL execution times must be demonstrated in the external orchestrator (for example Azure Data Factory or Synapse pipeline run history with Azure Monitor duration alerts) and confirmed manually.';
END
ELSE
BEGIN
    IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'msdb' AND state = 0)
        SET @MsdbOnline = 1;

    IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'SSISDB' AND state = 0)
        SET @SsisdbOnline = 1;

    /* SQL Agent ETL job inventory, retained run-duration history and notification setup. */
    IF @MsdbOnline = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
SELECT
    @p_jobs      = COUNT(*),
    @p_hist      = SUM(CASE WHEN h.Runs >= 1 THEN 1 ELSE 0 END),
    @p_trend     = SUM(CASE WHEN h.Runs >= 3 THEN 1 ELSE 0 END),
    @p_notified  = SUM(CASE WHEN j.notify_level_email > 0 OR j.notify_level_page > 0 OR j.notify_level_netsend > 0 THEN 1 ELSE 0 END)
FROM (
    SELECT DISTINCT
        sj.job_id,
        sj.notify_level_email,
        sj.notify_level_page,
        sj.notify_level_netsend
    FROM msdb.dbo.sysjobs AS sj
    LEFT JOIN msdb.dbo.sysjobsteps AS ss ON ss.job_id = sj.job_id
    LEFT JOIN msdb.dbo.syscategories AS sc ON sc.category_id = sj.category_id
    WHERE ss.subsystem IN (''SSIS'', ''CmdExec'', ''PowerShell'', ''Distribution'')
       OR sj.name LIKE ''%ETL%''
       OR sj.name LIKE ''%SSIS%''
       OR sj.name LIKE ''%Load%''
       OR sj.name LIKE ''%Import%''
       OR sj.name LIKE ''%Extract%''
       OR sj.name LIKE ''%Staging%''
       OR sj.name LIKE ''%Warehouse%''
       OR sj.name LIKE ''%Integration%''
       OR sc.name LIKE ''%ETL%''
       OR sc.name LIKE ''%SSIS%''
) AS j
OUTER APPLY (
    SELECT COUNT(*) AS Runs
    FROM msdb.dbo.sysjobhistory AS jh
    WHERE jh.job_id = j.job_id
      AND jh.step_id = 0
      AND jh.run_duration IS NOT NULL
      AND jh.run_date >= CONVERT(INT, CONVERT(CHAR(8), DATEADD(DAY, -90, GETDATE()), 112))
) AS h;';

            EXEC sys.sp_executesql @sql,
                 N'@p_jobs INT OUTPUT, @p_hist INT OUTPUT, @p_trend INT OUTPUT, @p_notified INT OUTPUT',
                 @p_jobs = @EtlJobCount OUTPUT,
                 @p_hist = @EtlJobsWithHistory OUTPUT,
                 @p_trend = @EtlJobsWithTrend OUTPUT,
                 @p_notified = @EtlJobsNotified OUTPUT;
        END TRY
        BEGIN CATCH
            SET @Notes = @Notes + N'SQL Agent job history could not be read (' + ISNULL(ERROR_MESSAGE(), N'unknown error') + N'). ';
        END CATCH

        BEGIN TRY
            SET @sql = N'
SELECT @p_alerts = COUNT(*)
FROM msdb.dbo.sysalerts AS a
WHERE a.enabled = 1
  AND ( a.performance_condition IS NOT NULL
        OR a.name LIKE ''%duration%''
        OR a.name LIKE ''%runtime%''
        OR a.name LIKE ''%run time%''
        OR a.name LIKE ''%long running%''
        OR a.name LIKE ''%ETL%'' );';

            EXEC sys.sp_executesql @sql,
                 N'@p_alerts INT OUTPUT',
                 @p_alerts = @DurationAlerts OUTPUT;
        END TRY
        BEGIN CATCH
            SET @Notes = @Notes + N'SQL Agent alerts could not be read (' + ISNULL(ERROR_MESSAGE(), N'unknown error') + N'). ';
        END CATCH

        SET @DbList = @DbList + N', msdb';
    END
    ELSE
    BEGIN
        SET @Notes = @Notes + N'msdb is not online, so SQL Agent ETL job history could not be inspected. ';
    END

    /* SSIS catalog execution history, retention window and logging level. */
    IF @SsisdbOnline = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
SELECT
    @p_exec = COUNT(*),
    @p_dur  = SUM(CASE WHEN e.start_time IS NOT NULL AND e.end_time IS NOT NULL THEN 1 ELSE 0 END)
FROM SSISDB.catalog.executions AS e
WHERE e.start_time >= DATEADD(DAY, -90, SYSDATETIMEOFFSET());';

            EXEC sys.sp_executesql @sql,
                 N'@p_exec INT OUTPUT, @p_dur INT OUTPUT',
                 @p_exec = @SsisExecCount OUTPUT,
                 @p_dur = @SsisExecWithDuration OUTPUT;
        END TRY
        BEGIN CATCH
            SET @Notes = @Notes + N'SSISDB execution history could not be read, which usually means the audit login lacks ssis_admin rights (' + ISNULL(ERROR_MESSAGE(), N'unknown error') + N'). ';
        END CATCH

        BEGIN TRY
            SET @sql = N'
SELECT
    @p_ret = MAX(CASE WHEN p.property_name = ''RETENTION_WINDOW'' THEN TRY_CONVERT(INT, CONVERT(NVARCHAR(100), p.property_value)) END),
    @p_log = MAX(CASE WHEN p.property_name = ''SERVER_LOGGING_LEVEL'' THEN TRY_CONVERT(INT, CONVERT(NVARCHAR(100), p.property_value)) END)
FROM SSISDB.catalog.catalog_properties AS p;';

            EXEC sys.sp_executesql @sql,
                 N'@p_ret INT OUTPUT, @p_log INT OUTPUT',
                 @p_ret = @SsisRetentionDays OUTPUT,
                 @p_log = @SsisLoggingLevel OUTPUT;
        END TRY
        BEGIN CATCH
            SET @Notes = @Notes + N'SSISDB catalog properties could not be read (' + ISNULL(ERROR_MESSAGE(), N'unknown error') + N'). ';
        END CATCH

        SET @DbList = @DbList + N', SSISDB';
    END

    SET @SsisRetentionDays = ISNULL(@SsisRetentionDays, 0);
    SET @SsisLoggingLevel = ISNULL(@SsisLoggingLevel, -1);
    SET @EtlJobCount = ISNULL(@EtlJobCount, 0);
    SET @EtlJobsWithHistory = ISNULL(@EtlJobsWithHistory, 0);
    SET @EtlJobsWithTrend = ISNULL(@EtlJobsWithTrend, 0);
    SET @EtlJobsNotified = ISNULL(@EtlJobsNotified, 0);
    SET @DurationAlerts = ISNULL(@DurationAlerts, 0);
    SET @SsisExecCount = ISNULL(@SsisExecCount, 0);
    SET @SsisExecWithDuration = ISNULL(@SsisExecWithDuration, 0);

    /* Persisted run-time baseline / duration-tracking objects in user databases. */
    WHILE 1 = 1
    BEGIN
        SELECT TOP (1) @db = d.name
        FROM sys.databases AS d
        WHERE d.name > @db
          AND d.database_id > 4
          AND d.state = 0
          AND d.name <> N'SSISDB'
          AND d.is_read_only = 0
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

        IF @@ROWCOUNT = 0 BREAK;

        SET @cnt = 0;

        BEGIN TRY
            SET @sql = N'
SELECT @p_cnt = COUNT(*)
FROM ' + QUOTENAME(@db) + N'.sys.objects AS o
WHERE o.type IN (''U'', ''V'')
  AND ( o.name LIKE ''%baseline%''
        OR o.name LIKE ''%threshold%''
        OR ( ( o.name LIKE ''%etl%'' OR o.name LIKE ''%package%'' OR o.name LIKE ''%pipeline%'' OR o.name LIKE ''%job%'' OR o.name LIKE ''%load%'' )
             AND ( o.name LIKE ''%duration%'' OR o.name LIKE ''%runtime%'' OR o.name LIKE ''%run_time%'' OR o.name LIKE ''%elapsed%'' OR o.name LIKE ''%execution%stat%'' OR o.name LIKE ''%exec%hist%'' ) ) );';

            EXEC sys.sp_executesql @sql,
                 N'@p_cnt INT OUTPUT',
                 @p_cnt = @cnt OUTPUT;
        END TRY
        BEGIN CATCH
            SET @cnt = 0;
            IF LEN(@Notes) < 1500
                SET @Notes = @Notes + N'Database [' + @db + N'] could not be inspected for baseline objects. ';
        END CATCH

        SET @cnt = ISNULL(@cnt, 0);
        SET @BaselineObjects = @BaselineObjects + @cnt;

        IF @cnt > 0 AND LEN(@BaselineDbs) < 3500
            SET @BaselineDbs = @BaselineDbs + CASE WHEN @BaselineDbs = '' THEN '' ELSE ', ' END + @db;

        IF LEN(@DbList) < 3500
            SET @DbList = @DbList + N', ' + @db;
    END

    /* Evidence classification. */
    IF ( @SsisExecWithDuration >= 1 AND @SsisRetentionDays >= 30 ) OR @EtlJobsWithTrend >= 1
        SET @HistoryEvidence = 1;

    IF @BaselineObjects > 0
        SET @BaselineEvidence = 1;

    IF @EtlJobsNotified > 0 OR @DurationAlerts > 0
        SET @MonitorEvidence = 1;

    IF @SsisdbOnline = 1 OR @EtlJobCount > 0
        SET @AnyEtl = 1;

    IF @AnyEtl = 0
    BEGIN
        SET @Score = 0;
        SET @Outcome = N'No ETL workload could be detected on this instance: the SSIS catalog is not installed and no SQL Agent job matches an ETL/SSIS/load naming or subsystem pattern, so no execution-time monitoring or baselining evidence exists on the database engine and any external orchestrator must be reviewed manually.';
    END
    ELSE IF @HistoryEvidence = 0
    BEGIN
        SET @Score = 0;
        SET @Outcome = N'An ETL workload exists but no usable run-duration history is retained, so execution times cannot be monitored or baselined from this instance.';
    END
    ELSE IF @BaselineEvidence = 1 AND @MonitorEvidence = 1
    BEGIN
        SET @Score = 3;
        SET @Outcome = N'ETL run-duration history is retained and trendable, persisted run-time baseline objects exist, and active duration monitoring/alerting is configured.';
    END
    ELSE IF @BaselineEvidence = 1 OR @MonitorEvidence = 1
    BEGIN
        SET @Score = 2;
        SET @Outcome = N'ETL run-duration history is retained, but only one of the two required controls is in place: either a persisted baseline exists without active monitoring/alerting, or monitoring is configured without a persisted run-time baseline.';
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Outcome = N'ETL run-duration history is retained, but there is no persisted run-time baseline and no duration monitoring or alerting configured, so slow runs are not detected against an expected norm.';
    END

    SET @DatabaseQueried = ISNULL(NULLIF(@DbList, ''), 'No database found to be queried');

    SET @Finding = @Outcome + N' Evidence: SSIS catalog '
        + CASE WHEN @SsisdbOnline = 1 THEN N'present' ELSE N'not installed' END
        + N'; SSISDB executions in the last 90 days = ' + CONVERT(NVARCHAR(20), @SsisExecCount)
        + N' (with start and end times = ' + CONVERT(NVARCHAR(20), @SsisExecWithDuration) + N')'
        + N'; SSISDB retention window = ' + CONVERT(NVARCHAR(20), @SsisRetentionDays) + N' day(s)'
        + N'; SSISDB server logging level = ' + CASE WHEN @SsisLoggingLevel < 0 THEN N'unavailable' ELSE CONVERT(NVARCHAR(20), @SsisLoggingLevel) END
        + N'. SQL Agent ETL-related jobs = ' + CONVERT(NVARCHAR(20), @EtlJobCount)
        + N'; with run_duration history in the last 90 days = ' + CONVERT(NVARCHAR(20), @EtlJobsWithHistory)
        + N'; with 3 or more retained runs (trendable) = ' + CONVERT(NVARCHAR(20), @EtlJobsWithTrend)
        + N'; with operator notification configured = ' + CONVERT(NVARCHAR(20), @EtlJobsNotified)
        + N'. Duration/performance-condition alerts = ' + CONVERT(NVARCHAR(20), @DurationAlerts)
        + N'. Persisted run-time baseline/duration-tracking objects = ' + CONVERT(NVARCHAR(20), @BaselineObjects)
        + CASE WHEN @BaselineDbs <> '' THEN N' (in ' + @BaselineDbs + N')' ELSE N'' END
        + N'.'
        + CASE WHEN @Notes <> '' THEN N' Collection notes: ' + @Notes ELSE N'' END;
END

SET @Score = ISNULL(@Score, 0);
SET @DatabaseQueried = ISNULL(NULLIF(@DatabaseQueried, ''), 'No database found to be queried');
SET @Finding = ISNULL(NULLIF(@Finding, ''), 'No evidence was collected.');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;