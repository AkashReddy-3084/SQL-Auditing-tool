/*
    Checklist 2.4.4 - ETL windows avoid contention with reporting/query workloads
    Scope : SERVER (msdb SQL Server Agent metadata)
    Mode  : READ-ONLY (temp tables only)
    Proxy : enabled ETL Agent job schedules are compared against the 08:00-18:00
            reporting/query window; reporting job start times are cross-referenced.
*/
SET NOCOUNT ON;

DECLARE @Result           NVARCHAR(30)   = N'Fail';
DECLARE @Score            INT            = 0;
DECLARE @DatabaseQueried  NVARCHAR(256)  = N'msdb';
DECLARE @Finding          NVARCHAR(4000) = N'';
DECLARE @EngineEdition    INT            = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @TotalEtl         INT            = 0;
DECLARE @ScheduledEtl     INT            = 0;
DECLARE @ConflictEtl      INT            = 0;
DECLARE @RptJobs          INT            = 0;
DECLARE @NearRpt          INT            = 0;
DECLARE @SampleConflicts  NVARCHAR(1500) = N'';
DECLARE @Failed           BIT            = 0;
DECLARE @ErrText          NVARCHAR(2000) = N'';
DECLARE @sql              NVARCHAR(MAX);

-- Reporting/query window expressed as minutes past midnight (08:00 - 18:00).
DECLARE @WindowStartMin INT = 8 * 60;
DECLARE @WindowEndMin   INT = 18 * 60;

IF OBJECT_ID('tempdb..#EtlJobs')  IS NOT NULL DROP TABLE #EtlJobs;
IF OBJECT_ID('tempdb..#EtlSched') IS NOT NULL DROP TABLE #EtlSched;
IF OBJECT_ID('tempdb..#RptSched') IS NOT NULL DROP TABLE #RptSched;

CREATE TABLE #EtlJobs
(
    job_id   UNIQUEIDENTIFIER NOT NULL,
    job_name NVARCHAR(128)    NOT NULL
);

CREATE TABLE #EtlSched
(
    job_name      NVARCHAR(128) NOT NULL,
    schedule_name NVARCHAR(128) NULL,
    start_time    INT           NOT NULL,
    start_min     INT           NOT NULL,
    end_min       INT           NOT NULL,
    conflicts     BIT           NOT NULL
);

CREATE TABLE #RptSched
(
    job_name  NVARCHAR(128) NOT NULL,
    start_min INT           NOT NULL
);

IF @EngineEdition = 5
BEGIN
    SET @Score           = 0;
    SET @DatabaseQueried = N'N/A - Azure SQL Database';
    SET @Finding         = N'Engine edition 5 (Azure SQL Database) has no SQL Server Agent, so ETL orchestration is external (Azure Data Factory, Elastic Jobs, Logic Apps) and the ETL window cannot be read from the instance. Manual review is required to confirm ETL windows do not overlap reporting/query hours.';
END
ELSE IF DB_ID('msdb') IS NULL
BEGIN
    SET @Score           = 0;
    SET @DatabaseQueried = N'N/A - msdb not present';
    SET @Finding         = N'The msdb database is not present or not accessible on this instance, so SQL Server Agent job schedules cannot be inspected. Manual review of the ETL schedule versus reporting/query hours is required.';
END
ELSE
BEGIN
    BEGIN TRY
        -- Enabled jobs that look like ETL / data-movement work.
        SET @sql = N'
            INSERT INTO #EtlJobs (job_id, job_name)
            SELECT DISTINCT j.job_id, j.name
            FROM msdb.dbo.sysjobs AS j
            LEFT JOIN msdb.dbo.sysjobsteps AS st
                   ON st.job_id = j.job_id
            WHERE j.enabled = 1
              AND ( j.name LIKE N''%ETL%''
                 OR j.name LIKE N''%extract%''
                 OR j.name LIKE N''%load%''
                 OR j.name LIKE N''%import%''
                 OR j.name LIKE N''%staging%''
                 OR j.name LIKE N''%SSIS%''
                 OR j.name LIKE N''%data%warehouse%''
                 OR j.name LIKE N''%ingest%''
                 OR st.subsystem = N''SSIS''
                 OR st.command LIKE N''%dtexec%'' );';
        EXEC sys.sp_executesql @sql;

        -- Enabled schedules of those ETL jobs, flagged when they run inside the reporting window.
        SET @sql = N'
            INSERT INTO #EtlSched (job_name, schedule_name, start_time, start_min, end_min, conflicts)
            SELECT e.job_name,
                   s.name,
                   s.active_start_time,
                   (s.active_start_time / 10000) * 60 + ((s.active_start_time / 100) % 100),
                   (s.active_end_time   / 10000) * 60 + ((s.active_end_time   / 100) % 100),
                   CASE
                       WHEN s.freq_subday_type IN (2, 4, 8)
                            THEN CASE WHEN (s.active_start_time / 10000) * 60 + ((s.active_start_time / 100) % 100) < @wEnd
                                       AND (s.active_end_time   / 10000) * 60 + ((s.active_end_time   / 100) % 100) > @wStart
                                      THEN 1 ELSE 0 END
                       ELSE CASE WHEN (s.active_start_time / 10000) * 60 + ((s.active_start_time / 100) % 100) >= @wStart
                                  AND (s.active_start_time / 10000) * 60 + ((s.active_start_time / 100) % 100) <  @wEnd
                                 THEN 1 ELSE 0 END
                   END
            FROM #EtlJobs AS e
            INNER JOIN msdb.dbo.sysjobschedules AS js
                    ON js.job_id = e.job_id
            INNER JOIN msdb.dbo.sysschedules AS s
                    ON s.schedule_id = js.schedule_id
            WHERE s.enabled = 1;';
        EXEC sys.sp_executesql @sql,
                               N'@wStart INT, @wEnd INT',
                               @wStart = @WindowStartMin,
                               @wEnd   = @WindowEndMin;

        -- Enabled reporting / analytics jobs, used as a contention cross-reference.
        SET @sql = N'
            INSERT INTO #RptSched (job_name, start_min)
            SELECT DISTINCT j.name,
                   (s.active_start_time / 10000) * 60 + ((s.active_start_time / 100) % 100)
            FROM msdb.dbo.sysjobs AS j
            INNER JOIN msdb.dbo.sysjobschedules AS js
                    ON js.job_id = j.job_id
            INNER JOIN msdb.dbo.sysschedules AS s
                    ON s.schedule_id = js.schedule_id
            WHERE j.enabled = 1
              AND s.enabled = 1
              AND ( j.name LIKE N''%report%''
                 OR j.name LIKE N''%cube%''
                 OR j.name LIKE N''%analysis%''
                 OR j.name LIKE N''%SSAS%''
                 OR j.name LIKE N''%refresh%''
                 OR j.name LIKE N''%dashboard%'' )
              AND NOT EXISTS (SELECT 1 FROM #EtlJobs AS e WHERE e.job_id = j.job_id);';
        EXEC sys.sp_executesql @sql;
    END TRY
    BEGIN CATCH
        SET @Failed  = 1;
        SET @ErrText = ERROR_MESSAGE();
    END CATCH

    IF @Failed = 1
    BEGIN
        SET @Score   = 0;
        SET @Finding = N'SQL Server Agent metadata in msdb could not be read (typically insufficient permission; SQLAgentReaderRole or sysadmin is required). Error: '
                     + ISNULL(@ErrText, N'unknown')
                     + N'. Manual review of ETL windows versus reporting/query hours is required.';
    END
    ELSE
    BEGIN
        SELECT @TotalEtl     = COUNT(*)                 FROM #EtlJobs;
        SELECT @ScheduledEtl = COUNT(DISTINCT job_name) FROM #EtlSched;
        SELECT @ConflictEtl  = COUNT(DISTINCT job_name) FROM #EtlSched WHERE conflicts = 1;
        SELECT @RptJobs      = COUNT(DISTINCT job_name) FROM #RptSched;

        SELECT @NearRpt = COUNT(*)
        FROM (
            SELECT DISTINCT es.job_name, rs.job_name AS rpt_name
            FROM #EtlSched AS es
            INNER JOIN #RptSched AS rs
                    ON ABS(es.start_min - rs.start_min) <= 30
        ) AS x;

        SET @SampleConflicts = ISNULL(STUFF((
            SELECT TOP (5) N'; ' + c.job_name + N' starts '
                   + RIGHT(N'000000' + CAST(c.start_time AS NVARCHAR(6)), 6)
            FROM (SELECT DISTINCT job_name, start_time FROM #EtlSched WHERE conflicts = 1) AS c
            ORDER BY c.job_name
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N''), N'');

        IF @TotalEtl = 0
        BEGIN
            SET @Score   = 0;
            SET @Finding = N'No enabled SQL Server Agent job on this instance matches an ETL/data-movement pattern (name containing ETL, extract, load, import, staging, SSIS, ingest or data warehouse, or an SSIS/dtexec job step). '
                         + CAST(@RptJobs AS NVARCHAR(10)) + N' enabled reporting-style job(s) were found. ETL may be orchestrated outside SQL Agent, so the ETL window versus reporting/query hours could not be evidenced and requires manual review.';
        END
        ELSE IF @ScheduledEtl = 0
        BEGIN
            SET @Score   = 0;
            SET @Finding = CAST(@TotalEtl AS NVARCHAR(10)) + N' enabled ETL job(s) were found but none has an enabled schedule, so no ETL run window is defined in SQL Agent (jobs are started on demand or by an external orchestrator). Separation from the 08:00-18:00 reporting/query window cannot be evidenced from instance metadata.';
        END
        ELSE IF @ConflictEtl = 0
        BEGIN
            SET @Score   = 3;
            SET @Finding = N'All ' + CAST(@ScheduledEtl AS NVARCHAR(10)) + N' scheduled ETL job(s) (of ' + CAST(@TotalEtl AS NVARCHAR(10))
                         + N' enabled ETL job(s)) run entirely outside the 08:00-18:00 reporting/query window. '
                         + CAST(@RptJobs AS NVARCHAR(10)) + N' enabled reporting-style job(s) were cross-referenced and '
                         + CAST(@NearRpt AS NVARCHAR(10)) + N' ETL/reporting schedule pair(s) start within 30 minutes of each other.';
        END
        ELSE IF @ConflictEtl * 2 <= @ScheduledEtl
        BEGIN
            SET @Score   = 2;
            SET @Finding = CAST(@ConflictEtl AS NVARCHAR(10)) + N' of ' + CAST(@ScheduledEtl AS NVARCHAR(10))
                         + N' scheduled ETL job(s) run inside the 08:00-18:00 reporting/query window: ' + @SampleConflicts
                         + N'. The majority of the ETL workload is windowed off-peak, but these jobs still contend with reporting/query activity. '
                         + CAST(@NearRpt AS NVARCHAR(10)) + N' ETL/reporting schedule pair(s) start within 30 minutes of each other.';
        END
        ELSE IF @ConflictEtl < @ScheduledEtl
        BEGIN
            SET @Score   = 1;
            SET @Finding = CAST(@ConflictEtl AS NVARCHAR(10)) + N' of ' + CAST(@ScheduledEtl AS NVARCHAR(10))
                         + N' scheduled ETL job(s) - more than half - run inside the 08:00-18:00 reporting/query window: ' + @SampleConflicts
                         + N'. ETL windows are largely unseparated from reporting/query hours. '
                         + CAST(@NearRpt AS NVARCHAR(10)) + N' ETL/reporting schedule pair(s) start within 30 minutes of each other.';
        END
        ELSE
        BEGIN
            SET @Score   = 0;
            SET @Finding = N'All ' + CAST(@ScheduledEtl AS NVARCHAR(10)) + N' scheduled ETL job(s) run inside the 08:00-18:00 reporting/query window: ' + @SampleConflicts
                         + N'. No separate off-peak ETL window exists, so extract/load activity contends directly with reporting and user query workloads. '
                         + CAST(@NearRpt AS NVARCHAR(10)) + N' ETL/reporting schedule pair(s) start within 30 minutes of each other.';
        END
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result              AS Result,
    @Score               AS Score,
    @DatabaseQueried     AS DatabaseQueried,
    LEFT(@Finding, 4000) AS Finding;

IF OBJECT_ID('tempdb..#EtlJobs')  IS NOT NULL DROP TABLE #EtlJobs;
IF OBJECT_ID('tempdb..#EtlSched') IS NOT NULL DROP TABLE #EtlSched;
IF OBJECT_ID('tempdb..#RptSched') IS NOT NULL DROP TABLE #RptSched;