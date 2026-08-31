-- Checklist: Load completion SLAs set and monitored
-- Scope: SERVER
-- Scoring: 3 = enabled jobs, enabled schedules, job-run history, and email-notifying jobs are all present; 2 = enabled jobs and at least two supporting categories are present; 1 = one job-monitoring category is present; 0 = no evidence or a source is unavailable
-- NOTE: Automated evidence confirms SQL Agent scheduling, execution history, and notification configuration; the actual SLA target and completion times require human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'SQL Agent SLA monitoring evidence unavailable';
DECLARE @EnabledJobCount INT = 0;
DECLARE @ScheduleCount INT = 0;
DECLARE @JobRunCount INT = 0;
DECLARE @NotifyingJobCount INT = 0;
DECLARE @SupportingEvidenceCount INT = 0;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT @EnabledJobCount = COUNT(*)
    FROM msdb.dbo.sysjobs
    WHERE enabled = 1;

    SELECT @ScheduleCount = COUNT(*)
    FROM msdb.dbo.sysjobschedules AS js
    INNER JOIN msdb.dbo.sysschedules AS s ON s.schedule_id = js.schedule_id
    WHERE s.enabled = 1;

    SELECT @JobRunCount = COUNT(*)
    FROM msdb.dbo.sysjobhistory
    WHERE step_id = 0;

    SELECT @NotifyingJobCount = COUNT(*)
    FROM msdb.dbo.sysjobs
    WHERE enabled = 1
      AND notify_level_email > 0;
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

SET @SupportingEvidenceCount =
    CASE WHEN @ScheduleCount > 0 THEN 1 ELSE 0 END
  + CASE WHEN @JobRunCount > 0 THEN 1 ELSE 0 END
  + CASE WHEN @NotifyingJobCount > 0 THEN 1 ELSE 0 END;

SET @Score = CASE
    WHEN @ReadError = 1 THEN 0
    WHEN @EnabledJobCount > 0 AND @ScheduleCount > 0
         AND @JobRunCount > 0 AND @NotifyingJobCount > 0 THEN 3
    WHEN @EnabledJobCount > 0 AND @SupportingEvidenceCount >= 2 THEN 2
    WHEN @EnabledJobCount > 0 OR @SupportingEvidenceCount > 0 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'enabled SQL Agent jobs = ', @EnabledJobCount,
    N'; enabled schedules = ', @ScheduleCount,
    N'; job runs = ', @JobRunCount,
    N'; enabled jobs with email notification = ', @NotifyingJobCount,
    CASE WHEN @ReadError = 1 THEN N'; one or more SQL Agent sources could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
