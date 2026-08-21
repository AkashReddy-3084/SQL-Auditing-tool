/*
    Checklist Item : 4.3.8 - Index maintenance (rebuild/reorganize) scheduled based on fragmentation
    Scope          : SERVER
    Read-only      : queries msdb job metadata only; no configuration is changed.
*/
SET NOCOUNT ON;

DECLARE @EngineEdition   INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Result          NVARCHAR(20);
DECLARE @Score           INT;
DECLARE @DatabaseQueried NVARCHAR(128) = N'msdb';
DECLARE @Finding         NVARCHAR(4000);

IF OBJECT_ID('tempdb..#IdxJobs') IS NOT NULL DROP TABLE #IdxJobs;
CREATE TABLE #IdxJobs
(
    JobName          SYSNAME NOT NULL,
    JobEnabled       BIT     NOT NULL,
    HasEnabledSched  BIT     NOT NULL,
    FragAware        BIT     NOT NULL
);

-- Azure SQL Database has no SQL Server Agent / msdb job metadata.
IF @EngineEdition = 5
BEGIN
    SET @Score           = 2;
    SET @DatabaseQueried = DB_NAME();
    SET @Finding         = N'Azure SQL Database detected (EngineEdition 5). SQL Server Agent and msdb job metadata are not available, so fragmentation-based index maintenance scheduling cannot be verified from T-SQL. Manually confirm Elastic Jobs, Azure Automation runbooks, or Automatic Tuning index management.';
END
ELSE
BEGIN
    ;WITH StepText AS
    (
        SELECT
            j.job_id,
            JobName    = j.name,
            JobEnabled = j.enabled,
            Cmd        = UPPER(CAST(s.command AS NVARCHAR(MAX)))
        FROM msdb.dbo.sysjobs AS j
        INNER JOIN msdb.dbo.sysjobsteps AS s
            ON s.job_id = j.job_id
    ),
    Flagged AS
    (
        SELECT
            st.job_id,
            st.JobName,
            st.JobEnabled,
            IsIndexMaint = CASE
                              WHEN st.Cmd LIKE '%ALTER INDEX%'
                                   AND (st.Cmd LIKE '%REBUILD%' OR st.Cmd LIKE '%REORGANIZE%') THEN 1
                              WHEN st.Cmd LIKE '%INDEXOPTIMIZE%'  THEN 1
                              WHEN st.Cmd LIKE '%DBREINDEX%'      THEN 1
                              WHEN st.Cmd LIKE '%INDEXDEFRAG%'    THEN 1
                              ELSE 0
                           END,
            IsFragAware  = CASE
                              WHEN st.Cmd LIKE '%DM_DB_INDEX_PHYSICAL_STATS%'   THEN 1
                              WHEN st.Cmd LIKE '%AVG_FRAGMENTATION_IN_PERCENT%' THEN 1
                              WHEN st.Cmd LIKE '%FRAGMENTATIONLEVEL%'           THEN 1
                              WHEN st.Cmd LIKE '%FRAGMENTATION%'                THEN 1
                              WHEN st.Cmd LIKE '%INDEXOPTIMIZE%'                THEN 1
                              ELSE 0
                           END
        FROM StepText AS st
    )
    INSERT INTO #IdxJobs (JobName, JobEnabled, HasEnabledSched, FragAware)
    SELECT
        f.JobName,
        MAX(CAST(f.JobEnabled AS INT)),
        MAX(CASE WHEN EXISTS (
                        SELECT 1
                        FROM msdb.dbo.sysjobschedules AS js
                        INNER JOIN msdb.dbo.sysschedules AS sc
                            ON sc.schedule_id = js.schedule_id
                        WHERE js.job_id = f.job_id
                          AND sc.enabled = 1)
                 THEN 1 ELSE 0 END),
        MAX(CAST(f.IsFragAware AS INT))
    FROM Flagged AS f
    WHERE f.IsIndexMaint = 1
    GROUP BY f.job_id, f.JobName;

    DECLARE @MaintPlanJobs INT = 0;

    SELECT @MaintPlanJobs = COUNT(DISTINCT j.job_id)
    FROM msdb.dbo.sysjobs AS j
    INNER JOIN msdb.dbo.sysjobsteps AS s
        ON s.job_id = j.job_id
    WHERE s.subsystem = 'SSIS'
      AND UPPER(CAST(s.command AS NVARCHAR(MAX))) LIKE '%SUBPLAN%';

    DECLARE @TotalJobs     INT = 0,
            @CompliantJobs INT = 0,
            @FragAwareJobs INT = 0,
            @ScheduledJobs INT = 0;

    SELECT
        @TotalJobs     = COUNT(*),
        @CompliantJobs = SUM(CASE WHEN JobEnabled = 1 AND HasEnabledSched = 1 AND FragAware = 1 THEN 1 ELSE 0 END),
        @FragAwareJobs = SUM(CASE WHEN FragAware = 1 THEN 1 ELSE 0 END),
        @ScheduledJobs = SUM(CASE WHEN JobEnabled = 1 AND HasEnabledSched = 1 THEN 1 ELSE 0 END)
    FROM #IdxJobs;

    DECLARE @JobList NVARCHAR(3000) =
        ISNULL(STUFF((
            SELECT TOP (10)
                   N', ' + j.JobName
                 + N' [enabled=' + CASE WHEN j.JobEnabled = 1 THEN N'Y' ELSE N'N' END
                 + N', scheduled=' + CASE WHEN j.HasEnabledSched = 1 THEN N'Y' ELSE N'N' END
                 + N', fragmentation-aware=' + CASE WHEN j.FragAware = 1 THEN N'Y' ELSE N'N' END + N']'
            FROM #IdxJobs AS j
            ORDER BY j.JobName
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'none');

    IF @CompliantJobs > 0
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'Found ' + CAST(@TotalJobs AS NVARCHAR(10)) + N' SQL Agent job(s) performing index rebuild/reorganize, of which '
                     + CAST(@CompliantJobs AS NVARCHAR(10)) + N' are enabled, attached to an enabled schedule, and driven by fragmentation thresholds. Jobs: ' + @JobList + N'.';
    END
    ELSE IF @TotalJobs > 0
    BEGIN
        SET @Score   = 2;
        SET @Finding = N'Found ' + CAST(@TotalJobs AS NVARCHAR(10)) + N' SQL Agent job(s) performing index rebuild/reorganize, but none satisfy all three conditions (enabled, enabled schedule, fragmentation-driven): '
                     + CAST(@ScheduledJobs AS NVARCHAR(10)) + N' are enabled and scheduled, '
                     + CAST(@FragAwareJobs AS NVARCHAR(10)) + N' reference fragmentation logic. Jobs: ' + @JobList + N'.';
    END
    ELSE IF @MaintPlanJobs > 0
    BEGIN
        SET @Score   = 2;
        SET @Finding = N'No SQL Agent job step contains an explicit index rebuild/reorganize command, but ' + CAST(@MaintPlanJobs AS NVARCHAR(10))
                     + N' SSIS maintenance-plan job(s) exist whose internal tasks cannot be read from T-SQL. Manually inspect these maintenance plans for a Rebuild/Reorganize Index task driven by fragmentation thresholds.';
    END
    ELSE
    BEGIN
        SET @Score   = 1;
        SET @Finding = N'No SQL Agent job or maintenance plan on this instance contains any index rebuild or reorganize command. Index fragmentation is not being remediated on a schedule.';
    END;
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    CAST(@Result AS NVARCHAR(20))          AS Result,
    CAST(@Score AS INT)                    AS Score,
    CAST(@DatabaseQueried AS NVARCHAR(128)) AS DatabaseQueried,
    CAST(@Finding AS NVARCHAR(4000))       AS Finding;

IF OBJECT_ID('tempdb..#IdxJobs') IS NOT NULL DROP TABLE #IdxJobs;