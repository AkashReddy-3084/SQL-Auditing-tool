/*
    Checklist Item : 10.3.4 - Alert thresholds tuned to avoid fatigue
    Scope          : SERVER
    Description    : Inspects SQL Server Agent alert definitions in msdb and reports whether
                     alert thresholds are tuned to prevent notification flooding (alert fatigue).
                     Untuned signals: no response throttling, informational severity targets,
                     very high historical firing counts, and alerts with no responder.
    Safety         : READ-ONLY. Only SELECT statements against msdb catalog data plus a local
                     temp table. No data, configuration or object is modified.
*/

SET NOCOUNT ON;

DECLARE @Result           NVARCHAR(20);
DECLARE @Score            INT           = 0;
DECLARE @DatabaseQueried  NVARCHAR(128) = N'msdb';
DECLARE @Finding          NVARCHAR(MAX) = N'';
DECLARE @EngineEdition    INT           = CAST(SERVERPROPERTY('EngineEdition') AS INT);

DECLARE @TotalAlerts      INT = 0;
DECLARE @EnabledAlerts    INT = 0;
DECLARE @Unthrottled      INT = 0;
DECLARE @LowSeverity      INT = 0;
DECLARE @HighFrequency    INT = 0;
DECLARE @NoResponder      INT = 0;
DECLARE @PerfCondAlerts   INT = 0;
DECLARE @FlaggedAlerts    INT = 0;
DECLARE @FlaggedList      NVARCHAR(MAX) = NULL;

IF @EngineEdition IN (5, 6, 9, 11)
BEGIN
    /* Azure SQL Database / Synapse / Azure SQL Edge - SQL Agent alerts do not exist here. */
    SET @DatabaseQueried = DB_NAME();
    SET @Score = 0;
    SET @Finding = N'MANUAL REVIEW REQUIRED: SQL Server Agent alerts are not available on this platform '
                 + N'(SERVERPROPERTY EngineEdition = ' + CAST(@EngineEdition AS NVARCHAR(10))
                 + N'). Alert threshold tuning is governed outside the database engine and must be reviewed '
                 + N'in Azure Monitor / Log Analytics alert rules (severity filters, aggregation windows, '
                 + N'suppression and auto-mitigate settings). No engine-side evidence of tuning could be collected.';
END
ELSE IF OBJECT_ID(N'msdb.dbo.sysalerts') IS NULL
BEGIN
    /* Object missing or not visible to the audit login - no evidence can be collected. */
    SET @Score = 0;
    SET @Finding = N'MANUAL REVIEW REQUIRED: msdb.dbo.sysalerts could not be read by the audit login, so SQL Server '
                 + N'Agent alert definitions and their tuning settings could not be enumerated. Grant read access to '
                 + N'msdb (for example membership of msdb SQLAgentReaderRole) and re-run, or review the alert list '
                 + N'manually in SQL Server Agent.';
END
ELSE
BEGIN
    IF OBJECT_ID(N'tempdb..#AlertTuning') IS NOT NULL
        DROP TABLE #AlertTuning;

    CREATE TABLE #AlertTuning
    (
        AlertName             SYSNAME        NOT NULL,
        IsEnabled             TINYINT        NOT NULL,
        Severity              INT            NULL,
        MessageId             INT            NULL,
        DelaySeconds          INT            NULL,
        OccurrenceCount       INT            NULL,
        HasPerfCondition      BIT            NOT NULL,
        IsUnthrottled         BIT            NOT NULL,
        IsLowSeverity         BIT            NOT NULL,
        IsHighFrequency       BIT            NOT NULL,
        IsNoResponder         BIT            NOT NULL
    );

    INSERT INTO #AlertTuning
    (
        AlertName, IsEnabled, Severity, MessageId, DelaySeconds, OccurrenceCount,
        HasPerfCondition, IsUnthrottled, IsLowSeverity, IsHighFrequency, IsNoResponder
    )
    SELECT
        a.name,
        a.enabled,
        a.severity,
        a.message_id,
        a.delay_between_responses,
        a.occurrence_count,
        CASE WHEN a.performance_condition IS NOT NULL AND LTRIM(RTRIM(a.performance_condition)) <> N''
             THEN 1 ELSE 0 END,
        /* No / negligible response throttling: the alert re-fires on every occurrence. */
        CASE WHEN a.enabled = 1 AND ISNULL(a.delay_between_responses, 0) < 60
             THEN 1 ELSE 0 END,
        /* Informational severities 1-15 raised as alerts are a classic fatigue source. */
        CASE WHEN a.enabled = 1 AND ISNULL(a.severity, 0) BETWEEN 1 AND 15
             THEN 1 ELSE 0 END,
        /* Historically very noisy alert - threshold demonstrably too sensitive. */
        CASE WHEN a.enabled = 1 AND ISNULL(a.occurrence_count, 0) >= 1000
             THEN 1 ELSE 0 END,
        /* Fires but notifies nobody and starts no job - pure noise in the alert log. */
        CASE WHEN a.enabled = 1
                  AND ISNULL(a.has_notification, 0) = 0
                  AND (a.job_id IS NULL
                       OR a.job_id = CAST(N'00000000-0000-0000-0000-000000000000' AS UNIQUEIDENTIFIER))
             THEN 1 ELSE 0 END
    FROM msdb.dbo.sysalerts AS a;

    SELECT
        @TotalAlerts    = COUNT(*),
        @EnabledAlerts  = SUM(CASE WHEN IsEnabled = 1 THEN 1 ELSE 0 END),
        @Unthrottled    = SUM(CASE WHEN IsUnthrottled = 1 THEN 1 ELSE 0 END),
        @LowSeverity    = SUM(CASE WHEN IsLowSeverity = 1 THEN 1 ELSE 0 END),
        @HighFrequency  = SUM(CASE WHEN IsHighFrequency = 1 THEN 1 ELSE 0 END),
        @NoResponder    = SUM(CASE WHEN IsNoResponder = 1 THEN 1 ELSE 0 END),
        @PerfCondAlerts = SUM(CASE WHEN IsEnabled = 1 AND HasPerfCondition = 1 THEN 1 ELSE 0 END),
        @FlaggedAlerts  = SUM(CASE WHEN IsEnabled = 1
                                    AND (IsUnthrottled = 1 OR IsLowSeverity = 1
                                         OR IsHighFrequency = 1 OR IsNoResponder = 1)
                                   THEN 1 ELSE 0 END)
    FROM #AlertTuning;

    SET @TotalAlerts    = ISNULL(@TotalAlerts, 0);
    SET @EnabledAlerts  = ISNULL(@EnabledAlerts, 0);
    SET @Unthrottled    = ISNULL(@Unthrottled, 0);
    SET @LowSeverity    = ISNULL(@LowSeverity, 0);
    SET @HighFrequency  = ISNULL(@HighFrequency, 0);
    SET @NoResponder    = ISNULL(@NoResponder, 0);
    SET @PerfCondAlerts = ISNULL(@PerfCondAlerts, 0);
    SET @FlaggedAlerts  = ISNULL(@FlaggedAlerts, 0);

    SELECT @FlaggedList = STUFF(
        (
            SELECT TOP (10)
                   N', ' + t.AlertName
                 + N' (delay=' + CAST(ISNULL(t.DelaySeconds, 0) AS NVARCHAR(20)) + N's'
                 + N', severity=' + CAST(ISNULL(t.Severity, 0) AS NVARCHAR(10))
                 + N', fired=' + CAST(ISNULL(t.OccurrenceCount, 0) AS NVARCHAR(20)) + N')'
            FROM #AlertTuning AS t
            WHERE t.IsEnabled = 1
              AND (t.IsUnthrottled = 1 OR t.IsLowSeverity = 1
                   OR t.IsHighFrequency = 1 OR t.IsNoResponder = 1)
            ORDER BY t.AlertName
            FOR XML PATH(N''), TYPE
        ).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N'');

    IF @TotalAlerts = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = N'No SQL Server Agent alerts are defined on this instance, so there are no alert thresholds '
                     + N'to tune. Severity 16-25 errors, corruption messages (823/824/825) and performance conditions '
                     + N'are raised to nobody.';
    END
    ELSE IF @EnabledAlerts = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = N'All ' + CAST(@TotalAlerts AS NVARCHAR(20)) + N' SQL Server Agent alert definition(s) on this '
                     + N'instance are disabled, so no thresholds are in effect and none can be considered tuned.';
    END
    ELSE IF @FlaggedAlerts = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = N'All ' + CAST(@EnabledAlerts AS NVARCHAR(20)) + N' enabled SQL Server Agent alert(s) (of '
                     + CAST(@TotalAlerts AS NVARCHAR(20)) + N' defined) show tuned thresholds: every alert throttles '
                     + N'repeat responses (delay_between_responses >= 60s), none targets informational severity 1-15, '
                     + N'none has fired 1000+ times, and every alert has an operator notification or response job. '
                     + N'Performance-condition alerts with explicit thresholds: '
                     + CAST(@PerfCondAlerts AS NVARCHAR(20)) + N'.';
    END
    ELSE IF (@FlaggedAlerts * 2) <= @EnabledAlerts
    BEGIN
        SET @Score = 2;
        SET @Finding = CAST(@FlaggedAlerts AS NVARCHAR(20)) + N' of ' + CAST(@EnabledAlerts AS NVARCHAR(20))
                     + N' enabled alert(s) show untuned thresholds (no repeat-response throttling: '
                     + CAST(@Unthrottled AS NVARCHAR(20)) + N'; informational severity 1-15: '
                     + CAST(@LowSeverity AS NVARCHAR(20)) + N'; fired 1000+ times: '
                     + CAST(@HighFrequency AS NVARCHAR(20)) + N'; no operator or job responder: '
                     + CAST(@NoResponder AS NVARCHAR(20)) + N'). Examples: '
                     + ISNULL(@FlaggedList, N'(none listed)') + N'.';
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Finding = N'Alert thresholds are not tuned: ' + CAST(@FlaggedAlerts AS NVARCHAR(20)) + N' of '
                     + CAST(@EnabledAlerts AS NVARCHAR(20)) + N' enabled alert(s) are untuned (no repeat-response '
                     + N'throttling: ' + CAST(@Unthrottled AS NVARCHAR(20)) + N'; informational severity 1-15: '
                     + CAST(@LowSeverity AS NVARCHAR(20)) + N'; fired 1000+ times: '
                     + CAST(@HighFrequency AS NVARCHAR(20)) + N'; no operator or job responder: '
                     + CAST(@NoResponder AS NVARCHAR(20)) + N'). Examples: '
                     + ISNULL(@FlaggedList, N'(none listed)') + N'.';
    END

    DROP TABLE #AlertTuning;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result              AS Result,
    @Score               AS Score,
    @DatabaseQueried     AS DatabaseQueried,
    LEFT(@Finding, 4000) AS Finding;