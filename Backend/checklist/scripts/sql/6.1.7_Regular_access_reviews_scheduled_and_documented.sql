-- Checklist: Regular access reviews scheduled and documented
-- Scope: SERVER
-- Scoring: 0=No evidence, 1=One-off jobs found, 2=Recurring scheduled jobs found, 3=Recurring jobs with explicit documentation/comments
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @JobCount INT = 0;
DECLARE @ScheduledCount INT = 0;
DECLARE @DocumentedCount INT = 0;

IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    -- Check for jobs related to access reviews
    SELECT @JobCount = COUNT(*)
    FROM msdb.dbo.sysjobs j
    WHERE j.enabled = 1
      AND (
        LOWER(j.name) LIKE '%access review%' OR LOWER(j.name) LIKE '%permission audit%' OR LOWER(j.name) LIKE '%user review%' OR LOWER(j.name) LIKE '%role review%' OR LOWER(j.name) LIKE '%security audit%'
        OR LOWER(j.description) LIKE '%access review%' OR LOWER(j.description) LIKE '%permission audit%' OR LOWER(j.description) LIKE '%user review%' OR LOWER(j.description) LIKE '%role review%' OR LOWER(j.description) LIKE '%security audit%'
      );

    IF @JobCount > 0
    BEGIN
        SET @Score = 1; -- At least one job exists

        -- Check if any are scheduled/recurring
        SELECT @ScheduledCount = COUNT(DISTINCT j.job_id)
        FROM msdb.dbo.sysjobs j
        INNER JOIN msdb.dbo.sysjobschedules js ON j.job_id = js.job_id
        INNER JOIN msdb.dbo.sysschedules s ON js.schedule_id = s.schedule_id
        WHERE j.enabled = 1
          AND s.freq_type IN (4, 8, 16, 32) -- Daily, Weekly, Monthly, Monthly by week
          AND (
            LOWER(j.name) LIKE '%access review%' OR LOWER(j.name) LIKE '%permission audit%' OR LOWER(j.name) LIKE '%user review%' OR LOWER(j.name) LIKE '%role review%' OR LOWER(j.name) LIKE '%security audit%'
            OR LOWER(j.description) LIKE '%access review%' OR LOWER(j.description) LIKE '%permission audit%' OR LOWER(j.description) LIKE '%user review%' OR LOWER(j.description) LIKE '%role review%' OR LOWER(j.description) LIKE '%security audit%'
          );

        IF @ScheduledCount > 0
        BEGIN
            SET @Score = 2; -- Recurring schedule found

            -- Check for documentation in description or comments
            SELECT @DocumentedCount = COUNT(DISTINCT j.job_id)
            FROM msdb.dbo.sysjobs j
            INNER JOIN msdb.dbo.sysjobschedules js ON j.job_id = js.job_id
            INNER JOIN msdb.dbo.sysschedules s ON js.schedule_id = s.schedule_id
            WHERE j.enabled = 1
              AND s.freq_type IN (4, 8, 16, 32)
              AND (
                LOWER(j.name) LIKE '%access review%' OR LOWER(j.name) LIKE '%permission audit%' OR LOWER(j.name) LIKE '%user review%' OR LOWER(j.name) LIKE '%role review%' OR LOWER(j.name) LIKE '%security audit%'
                OR LOWER(j.description) LIKE '%access review%' OR LOWER(j.description) LIKE '%permission audit%' OR LOWER(j.description) LIKE '%user review%' OR LOWER(j.description) LIKE '%role review%' OR LOWER(j.description) LIKE '%security audit%'
              )
              AND LEN(LTRIM(RTRIM(j.description))) > 10; -- Proxy for documentation

            IF @DocumentedCount > 0
            BEGIN
                SET @Score = 3;
            END
        END
    END
END
ELSE
BEGIN
    -- Azure SQL Database does not support SQL Agent jobs; degrade gracefully
    SET @Score = 0;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;
-- NOTE: This script provides automated evidence. Full compliance requires human review.