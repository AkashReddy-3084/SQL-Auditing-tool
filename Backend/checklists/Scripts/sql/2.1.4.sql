-- Checklist: Orchestration/dependency management exists (master package/pipeline or scheduler)
-- Scope: SERVER
-- Scoring: 3 = enabled jobs are scheduled and multi-step; 2 = enabled jobs are scheduled or multi-step; 1 = jobs exist without orchestration indicators; 0 = no jobs or metadata unavailable
-- NOTE: Automated evidence only; SSIS, external pipelines, and dependency correctness require human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'SQL Agent orchestration metadata could not be evaluated';
DECLARE @Jobs INT = 0;
DECLARE @Enabled INT = 0;
DECLARE @Scheduled INT = 0;
DECLARE @MultiStep INT = 0;
DECLARE @EngineEdition INT = ISNULL(CONVERT(INT, SERVERPROPERTY('EngineEdition')), 0);

IF @EngineEdition = 5
BEGIN
    SET @Score = 1;
    SET @Finding = N'Azure SQL Database does not host SQL Agent; external orchestration is not visible to this T-SQL probe';
END
ELSE
BEGIN
    BEGIN TRY
        SELECT @Jobs = COUNT(*),
               @Enabled = ISNULL(SUM(CASE WHEN j.enabled = 1 THEN 1 ELSE 0 END), 0),
               @Scheduled = ISNULL(SUM(CASE WHEN x.sched > 0 THEN 1 ELSE 0 END), 0),
               @MultiStep = ISNULL(SUM(CASE WHEN x.steps > 1 THEN 1 ELSE 0 END), 0)
        FROM msdb.dbo.sysjobs AS j
        OUTER APPLY
        (
            SELECT
                (SELECT COUNT(*) FROM msdb.dbo.sysjobschedules AS s WHERE s.job_id = j.job_id) AS sched,
                (SELECT COUNT(*) FROM msdb.dbo.sysjobsteps AS st WHERE st.job_id = j.job_id) AS steps
        ) AS x;

        SET @Score = CASE WHEN @Jobs = 0 THEN 0
                          WHEN @Enabled > 0 AND @Scheduled = @Enabled AND @MultiStep = @Enabled THEN 3
                          WHEN @Scheduled > 0 OR @MultiStep > 0 THEN 2
                          ELSE 1 END;
        SET @Finding = N'jobs=' + CONVERT(NVARCHAR(20), @Jobs) + N', enabled=' + CONVERT(NVARCHAR(20), @Enabled) + N', scheduled=' + CONVERT(NVARCHAR(20), @Scheduled) + N', multi_step=' + CONVERT(NVARCHAR(20), @MultiStep);
    END TRY
    BEGIN CATCH
        SET @Score = 0;
        SET @Finding = N'Unable to read SQL Agent orchestration metadata: ' + ERROR_MESSAGE();
    END CATCH;
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;