-- Checklist: Failures trigger notifications (email/alert/monitoring)
-- Scope: SERVER
-- Scoring: 3 = all jobs have notifications; 2 = >80% have notifications; 1 = some have notifications; 0 = no notifications configured

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No SQL Agent jobs found';

DECLARE @TotalJobs INT = 0;
DECLARE @NotifiedJobs INT = 0;
DECLARE @JobDetails NVARCHAR(MAX) = '';

-- Get total count of enabled jobs
SELECT @TotalJobs = COUNT(*) 
FROM msdb.dbo.sysjobs 
WHERE enabled = 1;

IF @TotalJobs = 0
BEGIN
    SET @Finding = 'No enabled SQL Agent jobs found to evaluate';
    SET @Score = 0;
END
ELSE
BEGIN
    -- Identify jobs that have notification enabled (Job level)
    -- notify_level_email_operator: 0 = Never, 1 = On Failure, 2 = On Success, 3 = Always
    SELECT @NotifiedJobs = COUNT(*)
    FROM msdb.dbo.sysjobs
    WHERE enabled = 1 
    AND notify_level_email_operator IN (1, 2, 3);

    -- Build finding list of enabled jobs WITHOUT notifications
    SELECT @JobDetails = STRING_AGG(QUOTENAME(name), ', ')
    FROM msdb.dbo.sysjobs
    WHERE enabled = 1 
    AND notify_level_email_operator = 0;

    -- Scoring logic based on proportion
    DECLARE @Ratio FLOAT = CAST(@NotifiedJobs AS FLOAT) / CAST(@TotalJobs AS FLOAT);

    IF @Ratio = 1.0
    BEGIN
        SET @Score = 3;
        SET @Finding = 'All enabled jobs have notifications configured.';
    END
    ELSE IF @Ratio >= 0.8
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Most jobs have notifications. Missing: ' + ISNULL(@JobDetails, 'None');
    END
    ELSE IF @Ratio > 0
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Few jobs have notifications. Missing: ' + ISNULL(@JobDetails, 'None');
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No enabled jobs have notifications configured.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;