/*
    Checklist item : 10.4.1 - ETL/job run history captured and retained
    Scope          : SERVER (msdb / SQL Server Agent job run history)
    Read-only      : Yes - catalog/registry reads only; the only writes are to session temp tables.
*/
SET NOCOUNT ON;

DECLARE @EngineEdition   INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Result          NVARCHAR(50);
DECLARE @Score           INT           = 1;
DECLARE @DatabaseQueried NVARCHAR(256) = N'msdb';
DECLARE @Finding         NVARCHAR(MAX) = N'';
DECLARE @Sql             NVARCHAR(MAX);
DECLARE @MsdbAccessible  BIT = 0;
DECLARE @CatchState      INT = 0;
DECLARE @TotalJobs       INT;
DECLARE @EnabledJobs     INT;
DECLARE @JobsWithHistory INT;
DECLARE @HistoryRows     BIGINT;
DECLARE @OldestRunDate   INT;
DECLARE @NewestRunDate   INT;
DECLARE @OldestDate      DATE;
DECLARE @NewestDate      DATE;
DECLARE @SpanDays        INT;
DECLARE @StaleDays       INT;
DECLARE @MaxRows         INT;
DECLARE @MaxRowsPerJob   INT;
DECLARE @CoveragePct     DECIMAL(9,1);

IF OBJECT_ID('tempdb..#AgentJobStats') IS NOT NULL DROP TABLE #AgentJobStats;
IF OBJECT_ID('tempdb..#AgentHistoryLimits') IS NOT NULL DROP TABLE #AgentHistoryLimits;

CREATE TABLE #AgentJobStats
(
    TotalJobs       INT    NULL,
    EnabledJobs     INT    NULL,
    JobsWithHistory INT    NULL,
    HistoryRows     BIGINT NULL,
    OldestRunDate   INT    NULL,
    NewestRunDate   INT    NULL
);

CREATE TABLE #AgentHistoryLimits
(
    SettingName  NVARCHAR(128) NOT NULL,
    SettingValue INT           NULL
);

IF @EngineEdition = 5
BEGIN
    SET @DatabaseQueried = DB_NAME();
    SET @Score   = 1;
    SET @Finding = N'Azure SQL Database (EngineEdition 5) detected. There is no SQL Server Agent and msdb job history is not exposed, so ETL/job run history cannot be verified from the engine. Run history for Elastic Jobs, Azure Data Factory / Synapse pipelines or any external scheduler must be evidenced manually, together with its retention period.';
END
ELSE
BEGIN
    SET @Sql = N'
SELECT
    (SELECT COUNT(*) FROM msdb.dbo.sysjobs) AS TotalJobs,
    (SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE enabled = 1) AS EnabledJobs,
    (SELECT COUNT(DISTINCT h1.job_id) FROM msdb.dbo.sysjobhistory AS h1) AS JobsWithHistory,
    (SELECT COUNT_BIG(*) FROM msdb.dbo.sysjobhistory AS h2) AS HistoryRows,
    (SELECT MIN(h3.run_date) FROM msdb.dbo.sysjobhistory AS h3 WHERE h3.run_date > 0) AS OldestRunDate,
    (SELECT MAX(h4.run_date) FROM msdb.dbo.sysjobhistory AS h4 WHERE h4.run_date > 0) AS NewestRunDate;';

    BEGIN TRY
        INSERT INTO #AgentJobStats (TotalJobs, EnabledJobs, JobsWithHistory, HistoryRows, OldestRunDate, NewestRunDate)
        EXEC sys.sp_executesql @Sql;

        SET @MsdbAccessible = 1;
    END TRY
    BEGIN CATCH
        SET @CatchState = 1;
    END CATCH;

    IF @MsdbAccessible = 0
    BEGIN
        SET @Score   = 1;
        SET @Finding = N'The SQL Server Agent history tables in msdb (sysjobs / sysjobhistory) could not be read - SQL Server Agent may not be installed, or the auditing login lacks access. Re-run with a login holding SQLAgentReaderRole (or higher) in msdb, or evidence ETL run history and its retention from the external scheduler.';
    END
    ELSE
    BEGIN
        SELECT
            @TotalJobs       = TotalJobs,
            @EnabledJobs     = EnabledJobs,
            @JobsWithHistory = JobsWithHistory,
            @HistoryRows     = HistoryRows,
            @OldestRunDate   = OldestRunDate,
            @NewestRunDate   = NewestRunDate
        FROM #AgentJobStats;

        /* Agent history retention caps live in the registry; unreadable on some editions, so best effort only. */
        SET @Sql = N'
BEGIN TRY
    DECLARE @RegMaxRows INT, @RegMaxRowsPerJob INT;

    EXEC master.dbo.xp_instance_regread
        N''HKEY_LOCAL_MACHINE'',
        N''SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent'',
        N''JobHistoryMaxRows'',
        @RegMaxRows OUTPUT,
        N''no_output'';

    EXEC master.dbo.xp_instance_regread
        N''HKEY_LOCAL_MACHINE'',
        N''SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent'',
        N''JobHistoryMaxRowsPerJob'',
        @RegMaxRowsPerJob OUTPUT,
        N''no_output'';

    INSERT INTO #AgentHistoryLimits (SettingName, SettingValue)
    VALUES (N''JobHistoryMaxRows'', @RegMaxRows), (N''JobHistoryMaxRowsPerJob'', @RegMaxRowsPerJob);
END TRY
BEGIN CATCH
    SET @RegMaxRows = NULL;
END CATCH;';

        BEGIN TRY
            EXEC sys.sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            SET @CatchState = 2;
        END CATCH;

        SELECT
            @MaxRows       = MAX(CASE WHEN l.SettingName = N'JobHistoryMaxRows'       THEN l.SettingValue END),
            @MaxRowsPerJob = MAX(CASE WHEN l.SettingName = N'JobHistoryMaxRowsPerJob' THEN l.SettingValue END)
        FROM #AgentHistoryLimits AS l;

        SET @OldestDate  = TRY_CONVERT(DATE, CONVERT(CHAR(8), @OldestRunDate));
        SET @NewestDate  = TRY_CONVERT(DATE, CONVERT(CHAR(8), @NewestRunDate));
        SET @SpanDays    = CASE WHEN @OldestDate IS NULL OR @NewestDate IS NULL THEN NULL
                                ELSE DATEDIFF(DAY, @OldestDate, @NewestDate) END;
        SET @StaleDays   = CASE WHEN @NewestDate IS NULL THEN NULL
                                ELSE DATEDIFF(DAY, @NewestDate, CAST(SYSDATETIME() AS DATE)) END;
        SET @CoveragePct = CASE WHEN ISNULL(@EnabledJobs, 0) = 0 THEN NULL
                                ELSE CAST(100.0 * @JobsWithHistory / @EnabledJobs AS DECIMAL(9,1)) END;

        IF ISNULL(@TotalJobs, 0) = 0
        BEGIN
            SET @Score   = 1;
            SET @Finding = N'No SQL Server Agent jobs are defined on this instance, so msdb holds no ETL/job run history. If ETL is scheduled externally (Azure Data Factory, Control-M, AutoSys, Airflow, Windows Task Scheduler), that platform''s run history and its retention period must be evidenced manually.';
        END
        ELSE IF ISNULL(@HistoryRows, 0) = 0 OR ISNULL(@JobsWithHistory, 0) = 0
        BEGIN
            SET @Score   = 0;
            SET @Finding = CONCAT(
                N'msdb.dbo.sysjobs defines ', @TotalJobs, N' job(s) (', ISNULL(@EnabledJobs, 0),
                N' enabled) but msdb.dbo.sysjobhistory contains 0 run history rows. ETL/job execution history is not being captured or has been purged entirely, so no run can be reconstructed or audited.');
        END
        ELSE
        BEGIN
            SET @Finding = CONCAT(
                N'SQL Agent run history found in msdb.dbo.sysjobhistory: ', @HistoryRows,
                N' history row(s) covering ', @JobsWithHistory, N' of ', ISNULL(@EnabledJobs, 0),
                N' enabled job(s) (coverage ', ISNULL(CONVERT(NVARCHAR(20), @CoveragePct), N'n/a'),
                N'%; ', @TotalJobs, N' job(s) defined in total). Retained window ',
                ISNULL(CONVERT(NVARCHAR(10), @OldestDate, 23), N'unknown'), N' to ',
                ISNULL(CONVERT(NVARCHAR(10), @NewestDate, 23), N'unknown'), N' = ',
                ISNULL(CONVERT(NVARCHAR(20), @SpanDays), N'unknown'),
                N' day(s); newest recorded run is ', ISNULL(CONVERT(NVARCHAR(20), @StaleDays), N'unknown'),
                N' day(s) old. Agent history caps: JobHistoryMaxRows = ',
                ISNULL(CONVERT(NVARCHAR(20), @MaxRows), N'not readable'),
                N', JobHistoryMaxRowsPerJob = ',
                ISNULL(CONVERT(NVARCHAR(20), @MaxRowsPerJob), N'not readable'), N'. ');

            IF ISNULL(@CoveragePct, 0) >= 90.0
               AND ISNULL(@SpanDays, 0) >= 30
               AND ISNULL(@StaleDays, 999999) <= 7
               AND (@MaxRows IS NULL OR @MaxRows >= 10000)
            BEGIN
                SET @Score   = 3;
                SET @Finding = CONCAT(@Finding, N'Run history is captured for effectively all enabled jobs, is current (within 7 days) and is retained for at least 30 days with an adequate history row cap.');
            END
            ELSE IF ISNULL(@SpanDays, 0) >= 7
                 AND ISNULL(@StaleDays, 999999) <= 30
                 AND ISNULL(@CoveragePct, 0) >= 50.0
            BEGIN
                SET @Score   = 2;
                SET @Finding = CONCAT(@Finding, N'History is captured but only partially meets the target: one or more of full job coverage (>=90%), a 30-day retained window, 7-day freshness, or a JobHistoryMaxRows cap of at least 10000 is not satisfied.');
            END
            ELSE
            BEGIN
                SET @Score   = 1;
                SET @Finding = CONCAT(@Finding, N'Retention or coverage is materially inadequate: the retained window is under 7 days, coverage is below 50% of enabled jobs, or the newest recorded run is more than 30 days old, so recent ETL executions cannot be reliably reconstructed.');
            END
        END
    END
END

IF OBJECT_ID('tempdb..#AgentJobStats') IS NOT NULL DROP TABLE #AgentJobStats;
IF OBJECT_ID('tempdb..#AgentHistoryLimits') IS NOT NULL DROP TABLE #AgentHistoryLimits;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;