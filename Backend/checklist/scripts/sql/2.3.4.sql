/*
    Checklist Item : 2.3.4 - Retry logic exists for transient failures
    Area           : Data Integration & ETL
    Scope          : SERVER (SQL Agent retry configuration is instance-wide, stored in msdb)
    Type           : Read-only. Catalog reads only; no data or configuration is modified.
    Output         : Result, Score, DatabaseQueried, Finding
*/
SET NOCOUNT ON;

DECLARE @Result           NVARCHAR(20)   = N'Fail';
DECLARE @Score            INT            = 1;
DECLARE @DatabaseQueried  NVARCHAR(128)  = N'msdb';
DECLARE @Finding          NVARCHAR(4000) = N'';

DECLARE @EngineEdition    INT            = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @MsdbReadable     BIT            = 0;
DECLARE @ErrorText        NVARCHAR(2000) = N'';
DECLARE @HasSsisdb        BIT            = CASE WHEN DB_ID(N'SSISDB') IS NOT NULL THEN 1 ELSE 0 END;

DECLARE @TotalSteps       INT = 0;
DECLARE @EtlSteps         INT = 0;
DECLARE @EtlWithRetry     INT = 0;
DECLARE @EtlWithInterval  INT = 0;
DECLARE @EtlJobs          INT = 0;
DECLARE @RetryPct         DECIMAL(5,1) = 0;
DECLARE @IntervalPct      DECIMAL(5,1) = 0;
DECLARE @SampleNoRetry    NVARCHAR(1000) = N'';

CREATE TABLE #EtlJobSteps
(
    job_name        NVARCHAR(128) NOT NULL,
    step_id         INT           NOT NULL,
    step_name       NVARCHAR(128) NOT NULL,
    subsystem       NVARCHAR(64)  NULL,
    retry_attempts  INT           NOT NULL,
    retry_interval  INT           NOT NULL,
    is_etl          BIT           NOT NULL
);

/* Azure SQL Database has no SQL Agent / msdb, so instance metadata cannot answer this item. */
IF @EngineEdition = 5
BEGIN
    SELECT @Score   = 1,
           @Finding = N'Engine edition 5 (Azure SQL Database) detected: SQL Server Agent and msdb are not available, so ETL retry configuration cannot be verified from instance metadata. Manually review retry policies in the orchestrator actually used (Azure Data Factory / Synapse pipeline retry count and interval, Elastic Jobs retry settings, or application-side transient-fault handling) before accepting this control.';
END
ELSE IF DB_ID(N'msdb') IS NULL
BEGIN
    SELECT @Score   = 1,
           @Finding = N'Database msdb is not present or not visible on this instance, so SQL Agent job step retry settings could not be inspected and no evidence of retry logic for transient failures could be collected.';
END
ELSE
BEGIN
    /* Dynamic SQL keeps the cross-database reference out of batch compilation and lets permission errors degrade gracefully. */
    BEGIN TRY
        EXEC sp_executesql N'
            INSERT INTO #EtlJobSteps (job_name, step_id, step_name, subsystem, retry_attempts, retry_interval, is_etl)
            SELECT  j.name,
                    s.step_id,
                    s.step_name,
                    s.subsystem,
                    ISNULL(s.retry_attempts, 0),
                    ISNULL(s.retry_interval, 0),
                    CASE
                        WHEN s.subsystem IN (N''SSIS'', N''CmdExec'', N''PowerShell'', N''Distribution'',
                                             N''LogReader'', N''Merge'', N''Snapshot'', N''QueueReader'',
                                             N''ANALYSISCOMMAND'', N''ANALYSISQUERY'')
                          OR j.name      LIKE N''%ETL%''      OR j.name      LIKE N''%Load%''
                          OR j.name      LIKE N''%Import%''   OR j.name      LIKE N''%Export%''
                          OR j.name      LIKE N''%Extract%''  OR j.name      LIKE N''%Stag%''
                          OR j.name      LIKE N''%Sync%''     OR j.name      LIKE N''%Transfer%''
                          OR j.name      LIKE N''%Replicat%'' OR j.name      LIKE N''%Warehouse%''
                          OR j.name      LIKE N''%Ingest%''   OR j.name      LIKE N''%Feed%''
                          OR s.step_name LIKE N''%ETL%''      OR s.step_name LIKE N''%Load%''
                          OR s.step_name LIKE N''%Import%''   OR s.step_name LIKE N''%Export%''
                          OR s.step_name LIKE N''%Extract%''  OR s.step_name LIKE N''%Stag%''
                          OR s.command   LIKE N''%dtexec%''   OR s.command   LIKE N''%SSISDB%''
                          OR s.command   LIKE N''%start_execution%''
                        THEN 1 ELSE 0
                    END
            FROM msdb.dbo.sysjobs      AS j
            INNER JOIN msdb.dbo.sysjobsteps AS s
                    ON s.job_id = j.job_id
            WHERE j.enabled = 1;';

        SET @MsdbReadable = 1;
    END TRY
    BEGIN CATCH
        SET @MsdbReadable = 0;
        SET @ErrorText    = LEFT(ERROR_MESSAGE(), 2000);
    END CATCH
END

IF @MsdbReadable = 1
BEGIN
    SELECT @TotalSteps      = COUNT(*),
           @EtlSteps        = SUM(CASE WHEN is_etl = 1 THEN 1 ELSE 0 END),
           @EtlWithRetry    = SUM(CASE WHEN is_etl = 1 AND retry_attempts > 0 THEN 1 ELSE 0 END),
           @EtlWithInterval = SUM(CASE WHEN is_etl = 1 AND retry_attempts > 0 AND retry_interval > 0 THEN 1 ELSE 0 END),
           @EtlJobs         = COUNT(DISTINCT CASE WHEN is_etl = 1 THEN job_name END)
    FROM #EtlJobSteps;

    SELECT @TotalSteps      = ISNULL(@TotalSteps, 0),
           @EtlSteps        = ISNULL(@EtlSteps, 0),
           @EtlWithRetry    = ISNULL(@EtlWithRetry, 0),
           @EtlWithInterval = ISNULL(@EtlWithInterval, 0),
           @EtlJobs         = ISNULL(@EtlJobs, 0);

    IF @EtlSteps > 0
        SET @RetryPct = CONVERT(DECIMAL(5,1), 100.0 * @EtlWithRetry / @EtlSteps);

    IF @EtlWithRetry > 0
        SET @IntervalPct = CONVERT(DECIMAL(5,1), 100.0 * @EtlWithInterval / @EtlWithRetry);

    SET @SampleNoRetry = ISNULL(STUFF((
            SELECT TOP (5) N'; ' + job_name + N' / ' + step_name
            FROM #EtlJobSteps
            WHERE is_etl = 1
              AND retry_attempts = 0
            ORDER BY job_name, step_id
            FOR XML PATH(''), TYPE).value('.', 'nvarchar(1000)'), 1, 2, N''), N'');

    IF @TotalSteps = 0
    BEGIN
        SELECT @Score   = 1,
               @Finding = N'No enabled SQL Server Agent job steps exist on this instance, so no ETL retry configuration is present to evaluate. If data integration runs outside SQL Agent (SSIS scheduled elsewhere, Azure Data Factory, application ETL), manually confirm that those pipelines define retry counts and back-off intervals for transient failures.';
    END
    ELSE IF @EtlSteps = 0
    BEGIN
        SELECT @Score   = 1,
               @Finding = N'Reviewed ' + CONVERT(NVARCHAR(20), @TotalSteps) + N' enabled SQL Agent job step(s), but none were identified as data integration / ETL work (no SSIS, CmdExec, PowerShell or replication subsystems, no dtexec / SSISDB commands and no ETL-style job or step names), so no retry logic for ETL transient failures could be evidenced. '
                        + CASE WHEN @HasSsisdb = 1 THEN N'An SSISDB catalog is present on this instance, so packages are likely executed by an external scheduler whose retry settings must be reviewed manually.' ELSE N'Manually verify that the actual ETL orchestrator configures retry attempts and intervals for transient failures.' END;
    END
    ELSE IF @RetryPct >= 90.0 AND @IntervalPct >= 50.0
    BEGIN
        SELECT @Score   = 3,
               @Finding = N'Retry logic is configured for transient failures: ' + CONVERT(NVARCHAR(20), @EtlWithRetry) + N' of ' + CONVERT(NVARCHAR(20), @EtlSteps)
                        + N' ETL job step(s) (' + CONVERT(NVARCHAR(20), @RetryPct) + N'%) across ' + CONVERT(NVARCHAR(20), @EtlJobs)
                        + N' enabled job(s) set retry_attempts > 0, and ' + CONVERT(NVARCHAR(20), @EtlWithInterval) + N' of those ('
                        + CONVERT(NVARCHAR(20), @IntervalPct) + N'%) also set a non-zero retry_interval so re-attempts are spaced rather than immediate.';
    END
    ELSE IF @RetryPct >= 90.0
    BEGIN
        SELECT @Score   = 2,
               @Finding = N'Retry attempts are widely configured (' + CONVERT(NVARCHAR(20), @EtlWithRetry) + N' of ' + CONVERT(NVARCHAR(20), @EtlSteps)
                        + N' ETL job step(s), ' + CONVERT(NVARCHAR(20), @RetryPct) + N'%), but only ' + CONVERT(NVARCHAR(20), @EtlWithInterval)
                        + N' of them (' + CONVERT(NVARCHAR(20), @IntervalPct) + N'%) use a non-zero retry_interval; the remainder retry immediately, which rarely clears a transient fault such as a deadlock, network drop or throttled source.';
    END
    ELSE IF @RetryPct >= 50.0
    BEGIN
        SELECT @Score   = 2,
               @Finding = N'Retry logic is only partially applied: ' + CONVERT(NVARCHAR(20), @EtlWithRetry) + N' of ' + CONVERT(NVARCHAR(20), @EtlSteps)
                        + N' ETL job step(s) (' + CONVERT(NVARCHAR(20), @RetryPct) + N'%) across ' + CONVERT(NVARCHAR(20), @EtlJobs)
                        + N' enabled job(s) set retry_attempts > 0. Steps without retry include: '
                        + CASE WHEN LEN(@SampleNoRetry) > 0 THEN @SampleNoRetry ELSE N'(none listed)' END + N'.';
    END
    ELSE
    BEGIN
        SELECT @Score   = 1,
               @Finding = N'Retry logic for transient failures is largely absent: only ' + CONVERT(NVARCHAR(20), @EtlWithRetry) + N' of '
                        + CONVERT(NVARCHAR(20), @EtlSteps) + N' ETL job step(s) (' + CONVERT(NVARCHAR(20), @RetryPct) + N'%) across '
                        + CONVERT(NVARCHAR(20), @EtlJobs) + N' enabled job(s) set retry_attempts > 0; the rest fail on the first error. Examples without retry: '
                        + CASE WHEN LEN(@SampleNoRetry) > 0 THEN @SampleNoRetry ELSE N'(none listed)' END + N'.';
    END
END
ELSE IF @EngineEdition <> 5 AND DB_ID(N'msdb') IS NOT NULL
BEGIN
    SELECT @Score   = 1,
           @Finding = N'SQL Agent job step retry settings in msdb could not be read with the audit login''s permissions (SQLAgentReaderRole or equivalent is required), so no evidence of ETL retry logic could be collected. Error: '
                    + CASE WHEN LEN(@ErrorText) > 0 THEN @ErrorText ELSE N'(not reported)' END
                    + N'. Re-run with sufficient rights or manually review retry_attempts / retry_interval on ETL job steps.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;

DROP TABLE #EtlJobSteps;