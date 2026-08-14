DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @AnyJobCount INT = 0;
DECLARE @EnabledScheduledJobCount INT = 0;
DECLARE @QSCount INT = 0;

-- Check for SQL Agent jobs related to wait stats/performance tuning
IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    -- Count any job matching keywords (covers disabled/unscheduled for score 2)
    SELECT @AnyJobCount = COUNT(*)
    FROM msdb.dbo.sysjobs j
    WHERE (LOWER(j.name) LIKE '%wait%' OR LOWER(j.name) LIKE '%performance%' OR LOWER(j.name) LIKE '%tuning%' OR LOWER(j.name) LIKE '%dmv%' OR LOWER(j.name) LIKE '%query store%');

    -- Count enabled & scheduled jobs (for score 3)
    IF OBJECT_ID('msdb.dbo.sysjobschedules') IS NOT NULL
    BEGIN
        SELECT @EnabledScheduledJobCount = COUNT(DISTINCT j.job_id)
        FROM msdb.dbo.sysjobs j
        INNER JOIN msdb.dbo.sysjobschedules js ON j.job_id = js.job_id
        WHERE j.enabled = 1
          AND (LOWER(j.name) LIKE '%wait%' OR LOWER(j.name) LIKE '%performance%' OR LOWER(j.name) LIKE '%tuning%' OR LOWER(j.name) LIKE '%dmv%' OR LOWER(j.name) LIKE '%query store%');
    END
END

-- Fallback: Check if Query Store is enabled on user databases
BEGIN TRY
    SELECT @QSCount = COUNT(*)
    FROM sys.databases
    WHERE database_id > 4
      AND state = 0
      AND is_query_store_on = 1;
END TRY
BEGIN CATCH
    SET @QSCount = 0;
END CATCH;

-- Assign score based on evidence hierarchy
IF @EnabledScheduledJobCount > 0
    SET @Score = 3;
ELSE IF @AnyJobCount > 0
    SET @Score = 2;
ELSE IF @QSCount > 0
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;