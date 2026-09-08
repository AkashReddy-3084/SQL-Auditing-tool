-- Checklist: Orchestration/dependency management exists (master package/pipeline or scheduler)
-- Scope: SERVER
-- Scoring: 3 = enabled jobs are on an enabled schedule and dependency chaining exists (multi-step jobs or a master job starting others); 2 = a scheduler or a master job exists without both signals, or the platform hosts orchestration externally; 1 = jobs exist but none are scheduled or chained; 0 = no jobs exist

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Orchestration evidence was unavailable';
DECLARE @Engine INT = ISNULL(CONVERT(INT, SERVERPROPERTY('EngineEdition')), 0);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Jobs INT = 0;
DECLARE @EnabledJobs INT = 0;
DECLARE @ScheduledJobs INT = 0;
DECLARE @ChainedJobs INT = 0;
DECLARE @MasterJobs INT = 0;
DECLARE @MasterNames NVARCHAR(MAX) = '';
DECLARE @ReadError BIT = 0;

CREATE TABLE #Orch
(
    Jobs INT NOT NULL,
    EnabledJobs INT NOT NULL,
    ScheduledJobs INT NOT NULL,
    ChainedJobs INT NOT NULL,
    MasterJobs INT NOT NULL,
    MasterNames NVARCHAR(MAX) NULL
);

IF @Engine <> 5
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT (SELECT COUNT(*) FROM msdb.dbo.sysjobs) AS Jobs, (SELECT COUNT(*) FROM msdb.dbo.sysjobs AS ej WHERE ej.enabled = 1) AS EnabledJobs, (SELECT COUNT(DISTINCT sj.job_id) FROM msdb.dbo.sysjobschedules AS sj INNER JOIN msdb.dbo.sysschedules AS sc ON sc.schedule_id = sj.schedule_id AND sc.enabled = 1) AS ScheduledJobs, (SELECT COUNT(DISTINCT st.job_id) FROM msdb.dbo.sysjobsteps AS st WHERE st.step_id > 1) AS ChainedJobs, (SELECT COUNT(DISTINCT ms.job_id) FROM msdb.dbo.sysjobsteps AS ms WHERE ms.command LIKE N''%sp[_]start[_]job%'') AS MasterJobs, (SELECT LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), mj.name), N'', ''), 300) FROM msdb.dbo.sysjobs AS mj WHERE EXISTS (SELECT 1 FROM msdb.dbo.sysjobsteps AS mt WHERE mt.job_id = mj.job_id AND mt.command LIKE N''%sp[_]start[_]job%'')) AS MasterNames;';
        INSERT INTO #Orch (Jobs, EnabledJobs, ScheduledJobs, ChainedJobs, MasterJobs, MasterNames)
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        SET @ReadError = 1;
    END CATCH
END

SELECT TOP (1)
       @Jobs = o.Jobs,
       @EnabledJobs = o.EnabledJobs,
       @ScheduledJobs = o.ScheduledJobs,
       @ChainedJobs = o.ChainedJobs,
       @MasterJobs = o.MasterJobs,
       @MasterNames = ISNULL(o.MasterNames, '')
FROM #Orch AS o;

IF @Engine = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database hosts no SQL Agent or SSIS catalog; ETL orchestration and dependency management run in an external scheduler (elastic jobs, Data Factory or Fabric pipelines) that the instance cannot report on';
END
ELSE IF @Jobs = 0
BEGIN
    SET @Score = 0;
    SET @Finding = CONCAT('No SQL Agent jobs exist on this instance, so no scheduler or master job orchestration was found',
                          CASE WHEN @ReadError = 1 THEN '; job metadata could not be read' ELSE '' END);
END
ELSE
BEGIN
    SET @Score = CASE WHEN @EnabledJobs > 0 AND @ScheduledJobs > 0 AND (@ChainedJobs > 0 OR @MasterJobs > 0) THEN 3
                      WHEN @ScheduledJobs > 0 OR @MasterJobs > 0 THEN 2
                      ELSE 1 END;
    SET @Finding = CONCAT('Agent jobs = ', @Jobs,
                          '; enabled = ', @EnabledJobs,
                          '; on an enabled schedule = ', @ScheduledJobs,
                          '; multi-step (dependency chained) = ', @ChainedJobs,
                          '; jobs starting other jobs = ', @MasterJobs,
                          CASE WHEN LEN(@MasterNames) > 0 THEN '; master jobs: ' + @MasterNames
                               ELSE '; no master job that starts other jobs was found' END);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
