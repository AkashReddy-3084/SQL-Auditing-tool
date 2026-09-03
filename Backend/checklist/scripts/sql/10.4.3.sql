SET NOCOUNT ON;

DECLARE @Result             nvarchar(20)  = N'Fail';
DECLARE @Score              int           = 0;
DECLARE @DatabaseQueried    nvarchar(128) = N'msdb';
DECLARE @Finding            nvarchar(max) = N'';

DECLARE @EngineEdition int = CONVERT(int, SERVERPROPERTY('EngineEdition'));

IF @EngineEdition = 5
BEGIN
    SET @Score = 0;
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
    SET @DatabaseQueried = N'master';
    SET @Finding = N'Azure SQL Database does not host SQL Agent job history; job duration trend monitoring cannot be verified on this engine.';
    SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
    RETURN;
END;

IF DB_ID(N'msdb') IS NULL
BEGIN
    SET @Score = 0;
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
    SET @DatabaseQueried = N'master';
    SET @Finding = N'msdb is not available; SQL Agent job duration history cannot be assessed.';
    SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
    RETURN;
END;

DECLARE @EnabledJobs int = 0;
DECLARE @JobsWithHistory int = 0;
DECLARE @JobsWithMultiRun int = 0;
DECLARE @JobsWithTrendDepth int = 0;
DECLARE @TotalHistoryRows int = 0;
DECLARE @OldestHistoryDays int = NULL;
DECLARE @MaxHistoryRows int = NULL;
DECLARE @MaxHistoryPerJob int = NULL;
DECLARE @DurationAlertCount int = 0;
DECLARE @AgentHistoryAvailable bit = 0;

BEGIN TRY
    IF OBJECT_ID(N'msdb.dbo.sysjobs', N'U') IS NOT NULL
       AND OBJECT_ID(N'msdb.dbo.sysjobhistory', N'U') IS NOT NULL
        SET @AgentHistoryAvailable = 1;
END TRY
BEGIN CATCH
    SET @AgentHistoryAvailable = 0;
END CATCH;

IF @AgentHistoryAvailable = 0
BEGIN
    SET @Score = 0;
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
    SET @Finding = N'SQL Agent job tables (msdb.dbo.sysjobs / sysjobhistory) are not accessible; cannot verify job duration trend monitoring.';
    SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
    RETURN;
END;

BEGIN TRY
    SELECT @EnabledJobs = COUNT(*)
    FROM msdb.dbo.sysjobs
    WHERE enabled = 1;

    ;WITH JobDurations AS (
        SELECT
            h.job_id,
            COUNT(*) AS run_cnt,
            COUNT(CASE WHEN h.run_duration IS NOT NULL THEN 1 END) AS duration_cnt
        FROM msdb.dbo.sysjobhistory AS h
        INNER JOIN msdb.dbo.sysjobs AS j
            ON j.job_id = h.job_id
        WHERE j.enabled = 1
          AND h.step_id = 0
        GROUP BY h.job_id
    )
    SELECT
        @JobsWithHistory    = COUNT(*),
        @JobsWithMultiRun   = SUM(CASE WHEN run_cnt >= 2 AND duration_cnt >= 2 THEN 1 ELSE 0 END),
        @JobsWithTrendDepth = SUM(CASE WHEN run_cnt >= 5 AND duration_cnt >= 5 THEN 1 ELSE 0 END),
        @TotalHistoryRows   = SUM(run_cnt)
    FROM JobDurations;

    SELECT
        @OldestHistoryDays =
            MAX(DATEDIFF(day,
                TRY_CONVERT(datetime,
                    STUFF(STUFF(CONVERT(char(8), h.run_date), 5, 0, '-'), 8, 0, '-')
                ),
                GETDATE()))
    FROM msdb.dbo.sysjobhistory AS h
    INNER JOIN msdb.dbo.sysjobs AS j
        ON j.job_id = h.job_id
    WHERE j.enabled = 1
      AND h.step_id = 0
      AND h.run_date > 0;

    IF OBJECT_ID(N'msdb.dbo.sysalerts', N'U') IS NOT NULL
    BEGIN
        SELECT @DurationAlertCount = COUNT(*)
        FROM msdb.dbo.sysalerts AS a
        WHERE a.enabled = 1
          AND (
                a.performance_condition LIKE N'%Duration%'
             OR a.performance_condition LIKE N'%RunTime%'
             OR a.name LIKE N'%duration%'
             OR a.name LIKE N'%long%run%'
             OR a.name LIKE N'%runtime%'
             OR a.name LIKE N'%run%time%'
             OR a.name LIKE N'%job%time%'
             OR a.name LIKE N'%SLA%'
             OR a.name LIKE N'%overrun%'
          );
    END;

    BEGIN TRY
        DECLARE @regHistoryMaxRows int = NULL;
        DECLARE @regHistoryMaxPerJob int = NULL;
        EXEC master.dbo.xp_instance_regread
            N'HKEY_LOCAL_MACHINE',
            N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
            N'JobHistoryMaxRows',
            @regHistoryMaxRows OUTPUT;
        EXEC master.dbo.xp_instance_regread
            N'HKEY_LOCAL_MACHINE',
            N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
            N'JobHistoryMaxRowsPerJob',
            @regHistoryMaxPerJob OUTPUT;
        SET @MaxHistoryRows = @regHistoryMaxRows;
        SET @MaxHistoryPerJob = @regHistoryMaxPerJob;
    END TRY
    BEGIN CATCH
        SET @MaxHistoryRows = NULL;
        SET @MaxHistoryPerJob = NULL;
    END CATCH;
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
    SET @Finding = N'Error assessing job duration history: ' + ERROR_MESSAGE();
    SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
    RETURN;
END CATCH;

DECLARE @HasTrendHistory bit = 0;
DECLARE @HasMultiRun bit = 0;
DECLARE @HasDurationAlert bit = 0;
DECLARE @HistoryRetained bit = 0;

IF ISNULL(@JobsWithTrendDepth, 0) > 0
    OR (ISNULL(@JobsWithMultiRun, 0) > 0 AND ISNULL(@OldestHistoryDays, 0) >= 7)
    SET @HasTrendHistory = 1;

IF ISNULL(@JobsWithMultiRun, 0) > 0
    SET @HasMultiRun = 1;

IF ISNULL(@DurationAlertCount, 0) > 0
    SET @HasDurationAlert = 1;

/* -1 means unlimited retention in SQL Agent history settings */
IF (ISNULL(@MaxHistoryRows, -1) = -1 OR ISNULL(@MaxHistoryRows, 0) >= 1000)
   AND (ISNULL(@MaxHistoryPerJob, -1) = -1 OR ISNULL(@MaxHistoryPerJob, 0) >= 100)
    SET @HistoryRetained = 1;

IF ISNULL(@EnabledJobs, 0) = 0 AND ISNULL(@JobsWithHistory, 0) = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No enabled SQL Agent jobs or job outcome history found; job duration trends are not monitored on this instance.';
END
ELSE IF @HasTrendHistory = 1 AND (@HasDurationAlert = 1 OR @HistoryRetained = 1)
BEGIN
    SET @Score = 3;
    SET @Finding =
        N'Job duration trend monitoring evidence found: enabled_jobs='
        + CONVERT(nvarchar(20), ISNULL(@EnabledJobs, 0))
        + N'; jobs_with_multi_run_duration='
        + CONVERT(nvarchar(20), ISNULL(@JobsWithMultiRun, 0))
        + N'; jobs_with_trend_depth(>=5 runs)='
        + CONVERT(nvarchar(20), ISNULL(@JobsWithTrendDepth, 0))
        + N'; history_span_days='
        + CONVERT(nvarchar(20), ISNULL(@OldestHistoryDays, 0))
        + N'; duration_related_alerts='
        + CONVERT(nvarchar(20), ISNULL(@DurationAlertCount, 0))
        + N'; jobhistory_maxrows='
        + ISNULL(CONVERT(nvarchar(20), @MaxHistoryRows), N'n/a')
        + N'; maxrows_per_job='
        + ISNULL(CONVERT(nvarchar(20), @MaxHistoryPerJob), N'n/a')
        + N'.';
END
ELSE IF @HasMultiRun = 1
BEGIN
    SET @Score = 2;
    SET @Finding =
        N'Partial duration-trend evidence: multi-run job history exists but monitoring controls are incomplete. enabled_jobs='
        + CONVERT(nvarchar(20), ISNULL(@EnabledJobs, 0))
        + N'; jobs_with_multi_run_duration='
        + CONVERT(nvarchar(20), ISNULL(@JobsWithMultiRun, 0))
        + N'; jobs_with_trend_depth(>=5 runs)='
        + CONVERT(nvarchar(20), ISNULL(@JobsWithTrendDepth, 0))
        + N'; history_span_days='
        + CONVERT(nvarchar(20), ISNULL(@OldestHistoryDays, 0))
        + N'; duration_related_alerts='
        + CONVERT(nvarchar(20), ISNULL(@DurationAlertCount, 0))
        + N'; jobhistory_maxrows='
        + ISNULL(CONVERT(nvarchar(20), @MaxHistoryRows), N'n/a')
        + N'; maxrows_per_job='
        + ISNULL(CONVERT(nvarchar(20), @MaxHistoryPerJob), N'n/a')
        + N'.';
END
ELSE IF ISNULL(@EnabledJobs, 0) > 0 OR ISNULL(@JobsWithHistory, 0) > 0
BEGIN
    SET @Score = 1;
    SET @Finding =
        N'Jobs exist but duration history is too thin for trend monitoring. enabled_jobs='
        + CONVERT(nvarchar(20), ISNULL(@EnabledJobs, 0))
        + N'; jobs_with_history='
        + CONVERT(nvarchar(20), ISNULL(@JobsWithHistory, 0))
        + N'; jobs_with_multi_run_duration='
        + CONVERT(nvarchar(20), ISNULL(@JobsWithMultiRun, 0))
        + N'; total_outcome_history_rows='
        + CONVERT(nvarchar(20), ISNULL(@TotalHistoryRows, 0))
        + N'; duration_related_alerts='
        + CONVERT(nvarchar(20), ISNULL(@DurationAlertCount, 0))
        + N'.';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = N'No usable SQL Agent job duration history found for trend monitoring.';
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;