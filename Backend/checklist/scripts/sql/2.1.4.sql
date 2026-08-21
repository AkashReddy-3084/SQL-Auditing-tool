-- Checklist 2.1.4 - Orchestration/dependency management exists (master package/pipeline or scheduler)
-- Read-only. SERVER scope. Inspects SQL Server Agent (msdb) and the Integration Services catalog (SSISDB).
SET NOCOUNT ON;

DECLARE @Result NVARCHAR(20);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(256);
DECLARE @Finding NVARCHAR(4000);

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition = 5
BEGIN
    SET @DatabaseQueried = DB_NAME();
    SET @Score = 1;
    SET @Finding = N'Azure SQL Database (EngineEdition 5): SQL Server Agent and the Integration Services catalog (SSISDB) are not available on this engine edition, so no in-engine orchestration or dependency-management artifact (master package, pipeline or scheduler) can be detected. Any orchestration for this platform is external (Azure Data Factory / Synapse pipelines, Elastic Jobs, Logic Apps) and cannot be evidenced from the database engine.';
END
ELSE
BEGIN
    DECLARE @HasMsdb BIT = 0;
    DECLARE @HasSsisdb BIT = 0;
    DECLARE @MsdbError NVARCHAR(400) = N'';
    DECLARE @SsisError NVARCHAR(400) = N'';
    DECLARE @TotalJobs INT = 0;
    DECLARE @EnabledJobs INT = 0;
    DECLARE @ScheduledJobs INT = 0;
    DECLARE @MultiStepJobs INT = 0;
    DECLARE @DependencyJobs INT = 0;
    DECLARE @SsisStepJobs INT = 0;
    DECLARE @SsisProjects INT = 0;
    DECLARE @SsisPackages INT = 0;
    DECLARE @sql NVARCHAR(MAX);

    IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'msdb' AND state = 0)
        SET @HasMsdb = 1;
    IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'SSISDB' AND state = 0)
        SET @HasSsisdb = 1;

    IF @HasMsdb = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
                SELECT
                    @pTotal   = COUNT(*),
                    @pEnabled = SUM(CASE WHEN j.enabled = 1 THEN 1 ELSE 0 END),
                    @pSched   = SUM(CASE WHEN j.enabled = 1 AND EXISTS (
                                        SELECT 1
                                        FROM ' + QUOTENAME(N'msdb') + N'.dbo.sysjobschedules AS js
                                        INNER JOIN ' + QUOTENAME(N'msdb') + N'.dbo.sysschedules AS s
                                                ON s.schedule_id = js.schedule_id
                                        WHERE js.job_id = j.job_id AND s.enabled = 1)
                                   THEN 1 ELSE 0 END),
                    @pMulti   = SUM(CASE WHEN (SELECT COUNT(*)
                                              FROM ' + QUOTENAME(N'msdb') + N'.dbo.sysjobsteps AS st
                                              WHERE st.job_id = j.job_id) > 1
                                   THEN 1 ELSE 0 END),
                    @pDep     = SUM(CASE WHEN EXISTS (
                                        SELECT 1
                                        FROM ' + QUOTENAME(N'msdb') + N'.dbo.sysjobsteps AS st
                                        WHERE st.job_id = j.job_id
                                          AND (st.on_success_action = 4 OR st.on_fail_action = 4))
                                   THEN 1 ELSE 0 END),
                    @pSsisStep = SUM(CASE WHEN EXISTS (
                                        SELECT 1
                                        FROM ' + QUOTENAME(N'msdb') + N'.dbo.sysjobsteps AS st
                                        WHERE st.job_id = j.job_id AND st.subsystem = N''SSIS'')
                                   THEN 1 ELSE 0 END)
                FROM ' + QUOTENAME(N'msdb') + N'.dbo.sysjobs AS j;';

            EXEC sys.sp_executesql @sql,
                 N'@pTotal INT OUTPUT, @pEnabled INT OUTPUT, @pSched INT OUTPUT, @pMulti INT OUTPUT, @pDep INT OUTPUT, @pSsisStep INT OUTPUT',
                 @pTotal = @TotalJobs OUTPUT, @pEnabled = @EnabledJobs OUTPUT, @pSched = @ScheduledJobs OUTPUT,
                 @pMulti = @MultiStepJobs OUTPUT, @pDep = @DependencyJobs OUTPUT, @pSsisStep = @SsisStepJobs OUTPUT;
        END TRY
        BEGIN CATCH
            SET @HasMsdb = 0;
            SET @MsdbError = N' msdb could not be read (' + LEFT(ERROR_MESSAGE(), 200) + N').';
        END CATCH
    END

    IF @HasSsisdb = 1
    BEGIN
        BEGIN TRY
            SET @sql = N'
                SELECT @pProj = (SELECT COUNT(*) FROM ' + QUOTENAME(N'SSISDB') + N'.catalog.projects),
                       @pPkg  = (SELECT COUNT(*) FROM ' + QUOTENAME(N'SSISDB') + N'.catalog.packages);';

            EXEC sys.sp_executesql @sql,
                 N'@pProj INT OUTPUT, @pPkg INT OUTPUT',
                 @pProj = @SsisProjects OUTPUT, @pPkg = @SsisPackages OUTPUT;
        END TRY
        BEGIN CATCH
            SET @HasSsisdb = 0;
            SET @SsisError = N' SSISDB could not be read (' + LEFT(ERROR_MESSAGE(), 200) + N').';
        END CATCH
    END

    SET @TotalJobs      = ISNULL(@TotalJobs, 0);
    SET @EnabledJobs    = ISNULL(@EnabledJobs, 0);
    SET @ScheduledJobs  = ISNULL(@ScheduledJobs, 0);
    SET @MultiStepJobs  = ISNULL(@MultiStepJobs, 0);
    SET @DependencyJobs = ISNULL(@DependencyJobs, 0);
    SET @SsisStepJobs   = ISNULL(@SsisStepJobs, 0);
    SET @SsisProjects   = ISNULL(@SsisProjects, 0);
    SET @SsisPackages   = ISNULL(@SsisPackages, 0);

    SET @DatabaseQueried = CASE
        WHEN @HasMsdb = 1 AND @HasSsisdb = 1 THEN N'msdb, SSISDB'
        WHEN @HasMsdb = 1 THEN N'msdb'
        WHEN @HasSsisdb = 1 THEN N'SSISDB'
        ELSE N'master' END;

    IF @HasMsdb = 0 AND @HasSsisdb = 0
    BEGIN
        SET @Score = 1;
        SET @Finding = N'Neither msdb (SQL Server Agent) nor SSISDB (Integration Services catalog) is online or readable on this instance, so no orchestration or dependency-management artifact - master package, pipeline or scheduler - could be detected.' + @MsdbError + @SsisError;
    END
    ELSE IF @TotalJobs = 0 AND @SsisPackages = 0
    BEGIN
        SET @Score = 1;
        SET @Finding = N'No orchestration artifact exists: 0 SQL Server Agent jobs are defined in msdb and 0 packages are deployed in the SSISDB catalog (' + CAST(@SsisProjects AS NVARCHAR(20)) + N' project(s)). There is no master package, pipeline or scheduler sequencing ETL work on this instance.' + @MsdbError + @SsisError;
    END
    ELSE IF @ScheduledJobs > 0
         AND (@MultiStepJobs > 0 OR @DependencyJobs > 0 OR @SsisStepJobs > 0 OR @SsisPackages > 0)
    BEGIN
        SET @Score = 3;
        SET @Finding = N'Scheduled, dependency-aware orchestration is in place: ' + CAST(@ScheduledJobs AS NVARCHAR(20)) + N' of ' + CAST(@EnabledJobs AS NVARCHAR(20)) + N' enabled SQL Agent job(s) (out of ' + CAST(@TotalJobs AS NVARCHAR(20)) + N' defined) are bound to an enabled schedule; ' + CAST(@MultiStepJobs AS NVARCHAR(20)) + N' job(s) are multi-step, ' + CAST(@DependencyJobs AS NVARCHAR(20)) + N' job(s) use explicit goto-step flow control (on_success_action/on_fail_action = 4), and ' + CAST(@SsisStepJobs AS NVARCHAR(20)) + N' job(s) execute SSIS packages. The SSISDB catalog holds ' + CAST(@SsisProjects AS NVARCHAR(20)) + N' project(s) and ' + CAST(@SsisPackages AS NVARCHAR(20)) + N' package(s).' + @MsdbError + @SsisError;
    END
    ELSE
    BEGIN
        SET @Score = 2;
        SET @Finding = N'Orchestration artifacts exist but are not scheduled or sequenced: ' + CAST(@TotalJobs AS NVARCHAR(20)) + N' SQL Agent job(s) defined, ' + CAST(@EnabledJobs AS NVARCHAR(20)) + N' enabled, only ' + CAST(@ScheduledJobs AS NVARCHAR(20)) + N' bound to an enabled schedule; ' + CAST(@MultiStepJobs AS NVARCHAR(20)) + N' multi-step job(s), ' + CAST(@DependencyJobs AS NVARCHAR(20)) + N' job(s) with goto-step flow control, ' + CAST(@SsisStepJobs AS NVARCHAR(20)) + N' job(s) invoking SSIS; SSISDB holds ' + CAST(@SsisProjects AS NVARCHAR(20)) + N' project(s) and ' + CAST(@SsisPackages AS NVARCHAR(20)) + N' package(s). Execution order and dependency management are therefore not demonstrably centralised.' + @MsdbError + @SsisError;
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;