/*
    Checklist Item : 10.4.3 - Job duration trends monitored
    Area           : Monitoring & Observability
    Scope          : SERVER (msdb / SQL Server Agent)
    Type           : Read-only T-SQL
    Notes          : Reads msdb job history only. No permanent data is modified.
*/

SET NOCOUNT ON;

DECLARE @EngineEdition    INT            = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @DatabaseQueried  NVARCHAR(128)  = N'msdb';
DECLARE @Result           NVARCHAR(20)   = N'Fail';
DECLARE @Score            INT            = 1;
DECLARE @Finding          NVARCHAR(4000) = N'';
DECLARE @Sql              NVARCHAR(MAX);
DECLARE @ErrMsg           NVARCHAR(2000) = NULL;
DECLARE @EnabledJobs      INT            = NULL;
DECLARE @JobsWithHistory  INT            = NULL;
DECLARE @Trendable        INT            = NULL;
DECLARE @WindowDays       INT            = NULL;
DECLARE @ArtifactCount    INT            = 0;
DECLARE @ArtifactList     NVARCHAR(2000) = NULL;

IF OBJECT_ID('tempdb..#JobMetrics') IS NOT NULL DROP TABLE #JobMetrics;
IF OBJECT_ID('tempdb..#Artifacts')  IS NOT NULL DROP TABLE #Artifacts;

CREATE TABLE #JobMetrics
(
    EnabledJobs              INT NULL,
    JobsWithHistory          INT NULL,
    JobsWithTrendableHistory INT NULL,
    HistoryWindowDays        INT NULL
);

CREATE TABLE #Artifacts
(
    ArtifactName NVARCHAR(400) NOT NULL
);

IF @EngineEdition = 5
BEGIN
    SET @DatabaseQueried = DB_NAME();
    SET @Score   = 1;
    SET @Finding = N'Azure SQL Database (EngineEdition 5) does not expose SQL Server Agent or msdb job history, so job duration trends cannot be evidenced from this instance. Duration telemetry for Elastic Jobs / Azure Automation runbooks must be verified manually.';
END
ELSE IF DB_ID('msdb') IS NULL
BEGIN
    SET @Score   = 1;
    SET @Finding = N'The msdb database is not present or not accessible on this instance, so SQL Server Agent job duration history could not be inspected. Manual verification of job duration trend monitoring is required.';
END
ELSE
BEGIN
    /* ---- Job history depth and coverage ---- */
    BEGIN TRY
        SET @Sql = N'
SELECT
    (SELECT COUNT(*)
       FROM msdb.dbo.sysjobs
      WHERE enabled = 1) AS EnabledJobs,
    (SELECT COUNT(DISTINCT jh.job_id)
       FROM msdb.dbo.sysjobhistory AS jh
      WHERE jh.step_id = 0) AS JobsWithHistory,
    (SELECT COUNT(*)
       FROM (SELECT jh2.job_id
               FROM msdb.dbo.sysjobhistory AS jh2
              WHERE jh2.step_id = 0
              GROUP BY jh2.job_id
             HAVING COUNT(*) >= 10) AS t) AS JobsWithTrendableHistory,
    (SELECT ISNULL(DATEDIFF(DAY,
                            MIN(CONVERT(DATE, CONVERT(CHAR(8), jh3.run_date), 112)),
                            MAX(CONVERT(DATE, CONVERT(CHAR(8), jh3.run_date), 112))) + 1, 0)
       FROM msdb.dbo.sysjobhistory AS jh3
      WHERE jh3.step_id = 0
        AND jh3.run_date > 19000101) AS HistoryWindowDays;';

        INSERT INTO #JobMetrics (EnabledJobs, JobsWithHistory, JobsWithTrendableHistory, HistoryWindowDays)
        EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        SET @ErrMsg = ERROR_MESSAGE();
    END CATCH

    /* ---- Artifact 1: Agent jobs that consume job duration history ---- */
    BEGIN TRY
        SET @Sql = N'
SELECT DISTINCT LEFT(N''Agent job: '' + j.name, 400)
  FROM msdb.dbo.sysjobs AS j
  LEFT JOIN msdb.dbo.sysjobsteps AS s
    ON s.job_id = j.job_id
 WHERE j.enabled = 1
   AND (   j.name LIKE N''%duration%''
        OR j.name LIKE N''%runtime%''
        OR j.name LIKE N''%run time%''
        OR j.name LIKE N''%long%runn%''
        OR (j.name LIKE N''%job%'' AND j.name LIKE N''%monitor%'')
        OR s.command LIKE N''%sysjobhistory%''
        OR s.command LIKE N''%run_duration%''
        OR s.command LIKE N''%sp_help_jobhistory%'');';

        INSERT INTO #Artifacts (ArtifactName)
        EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        SET @ErrMsg = ISNULL(@ErrMsg + N' | ', N'') + ERROR_MESSAGE();
    END CATCH

    /* ---- Artifact 2: running data collector sets (job/perf trending) ---- */
    BEGIN TRY
        SET @Sql = N'
SELECT DISTINCT LEFT(N''Data collector set: '' + cs.name, 400)
  FROM msdb.dbo.syscollector_collection_sets AS cs
 WHERE cs.is_running = 1;';

        INSERT INTO #Artifacts (ArtifactName)
        EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        SET @ErrMsg = ISNULL(@ErrMsg + N' | ', N'') + ERROR_MESSAGE();
    END CATCH

    SELECT @EnabledJobs     = ISNULL(EnabledJobs, 0),
           @JobsWithHistory = ISNULL(JobsWithHistory, 0),
           @Trendable       = ISNULL(JobsWithTrendableHistory, 0),
           @WindowDays      = ISNULL(HistoryWindowDays, 0)
      FROM #JobMetrics;

    SELECT @ArtifactCount = COUNT(*) FROM #Artifacts;

    SET @ArtifactList =
        STUFF((SELECT N'; ' + a.ArtifactName
                 FROM (SELECT DISTINCT TOP (10) ArtifactName
                         FROM #Artifacts
                        ORDER BY ArtifactName) AS a
                  FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(2000)'), 1, 2, N'');

    IF @EnabledJobs IS NULL
    BEGIN
        SET @Score   = 1;
        SET @Finding = N'SQL Server Agent job history in msdb could not be read by the audit login'
                     + ISNULL(N' (error: ' + @ErrMsg + N')', N'')
                     + N'. Job duration trend monitoring requires manual verification.';
    END
    ELSE IF @EnabledJobs = 0
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'No enabled SQL Server Agent jobs exist on this instance ('
                     + CAST(@JobsWithHistory AS NVARCHAR(20))
                     + N' job(s) with historical outcome rows), so there are no job duration trends to monitor.';
    END
    ELSE IF @JobsWithHistory = 0
    BEGIN
        SET @Score   = 0;
        SET @Finding = CAST(@EnabledJobs AS NVARCHAR(20))
                     + N' enabled SQL Server Agent job(s) exist, but msdb.dbo.sysjobhistory contains no job outcome rows at all. No execution duration data is retained, so duration trends cannot be monitored.';
    END
    ELSE IF @WindowDays >= 30
        AND (@Trendable * 100) >= (80 * @EnabledJobs)
        AND @ArtifactCount >= 1
    BEGIN
        SET @Score   = 3;
        SET @Finding = N'Job duration history spans ' + CAST(@WindowDays AS NVARCHAR(20)) + N' day(s); '
                     + CAST(@Trendable AS NVARCHAR(20)) + N' of ' + CAST(@EnabledJobs AS NVARCHAR(20))
                     + N' enabled job(s) have 10+ recorded executions, and ' + CAST(@ArtifactCount AS NVARCHAR(20))
                     + N' monitoring artifact(s) consume that duration data: ' + ISNULL(@ArtifactList, N'(none listed)') + N'.';
    END
    ELSE IF @WindowDays >= 30 AND @Trendable >= 1
    BEGIN
        SET @Score   = 2;
        SET @Finding = N'Job duration history is retained (' + CAST(@WindowDays AS NVARCHAR(20)) + N' day window; '
                     + CAST(@Trendable AS NVARCHAR(20)) + N' of ' + CAST(@EnabledJobs AS NVARCHAR(20))
                     + N' enabled job(s) with 10+ executions), but no Agent job or data collector set was found that reads job duration history'
                     + CASE WHEN @ArtifactCount = 0 THEN N'' ELSE N' (' + ISNULL(@ArtifactList, N'') + N')' END
                     + N', so duration trends do not appear to be actively reviewed.';
    END
    ELSE
    BEGIN
        SET @Score   = 1;
        SET @Finding = N'Job duration history is too shallow or sparse for trend analysis: retained window '
                     + CAST(@WindowDays AS NVARCHAR(20)) + N' day(s), '
                     + CAST(@Trendable AS NVARCHAR(20)) + N' of ' + CAST(@EnabledJobs AS NVARCHAR(20))
                     + N' enabled job(s) have 10+ recorded executions, and ' + CAST(@ArtifactCount AS NVARCHAR(20))
                     + N' duration-monitoring artifact(s) were found'
                     + CASE WHEN @ArtifactCount = 0 THEN N'' ELSE N': ' + ISNULL(@ArtifactList, N'') END + N'.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result          AS Result,
       @Score           AS Score,
       @DatabaseQueried AS DatabaseQueried,
       @Finding         AS Finding;

IF OBJECT_ID('tempdb..#JobMetrics') IS NOT NULL DROP TABLE #JobMetrics;
IF OBJECT_ID('tempdb..#Artifacts')  IS NOT NULL DROP TABLE #Artifacts;