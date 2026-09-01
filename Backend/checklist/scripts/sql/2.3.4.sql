-- Checklist: Retry logic exists for transient failures
-- Scope: SERVER
-- Scoring: 3 = at least 90% of Agent job steps configure retry attempts; 2 = at least 50% do, or the platform exposes no Agent metadata; 1 = some steps configure retries; 0 = no step configures retries, or no job steps exist

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Retry configuration evidence was unavailable';
DECLARE @Engine INT = ISNULL(CONVERT(INT, SERVERPROPERTY('EngineEdition')), 0);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Steps INT = 0;
DECLARE @WithRetry INT = 0;
DECLARE @RetryPct DECIMAL(6, 2) = 0;
DECLARE @Jobs INT = 0;
DECLARE @JobsNoRetry INT = 0;
DECLARE @NoRetryList NVARCHAR(MAX) = '';
DECLARE @ReadError BIT = 0;

CREATE TABLE #Retry
(
    JobName NVARCHAR(256) NOT NULL,
    RetryAttempts INT NOT NULL
);

IF @Engine <> 5
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT j.name, ISNULL(s.retry_attempts, 0) FROM msdb.dbo.sysjobsteps AS s INNER JOIN msdb.dbo.sysjobs AS j ON j.job_id = s.job_id;';
        INSERT INTO #Retry (JobName, RetryAttempts) EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        SET @ReadError = 1;
    END CATCH
END

SELECT @Steps = COUNT(*),
       @WithRetry = ISNULL(SUM(CASE WHEN r.RetryAttempts > 0 THEN 1 ELSE 0 END), 0)
FROM #Retry AS r;

SELECT @Jobs = COUNT(*),
       @JobsNoRetry = ISNULL(SUM(CASE WHEN x.MaxRetry = 0 THEN 1 ELSE 0 END), 0),
       @NoRetryList = ISNULL(LEFT(STRING_AGG(CASE WHEN x.MaxRetry = 0 THEN CONVERT(NVARCHAR(MAX), x.JobName) END, ', '), 400), '')
FROM (SELECT r.JobName, MAX(r.RetryAttempts) AS MaxRetry FROM #Retry AS r GROUP BY r.JobName) AS x;

SET @RetryPct = CASE WHEN @Steps = 0 THEN 0
                     ELSE CONVERT(DECIMAL(6, 2), 100.0 * @WithRetry / NULLIF(@Steps, 0)) END;

IF @Engine = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database hosts no SQL Agent, so job step retry settings cannot be read; transient-fault retries are supplied by the client driver and the external orchestration service';
END
ELSE IF @Steps = 0
BEGIN
    SET @Score = 0;
    SET @Finding = CONCAT('No SQL Agent job steps exist on this instance, so no retry attempts are configured anywhere',
                          CASE WHEN @ReadError = 1 THEN '; job step metadata could not be read' ELSE '' END);
END
ELSE
BEGIN
    SET @Score = CASE WHEN @RetryPct >= 90 THEN 3
                      WHEN @RetryPct >= 50 THEN 2
                      WHEN @WithRetry > 0 THEN 1
                      ELSE 0 END;
    SET @Finding = CONCAT('Agent job steps = ', @Steps,
                          '; steps with retry_attempts greater than 0 = ', @WithRetry,
                          ' (', @RetryPct, '%)',
                          '; jobs = ', @Jobs,
                          '; jobs with no retry on any step = ', @JobsNoRetry,
                          CASE WHEN @JobsNoRetry = 0 THEN '; every job configures retries'
                               ELSE '; jobs without retries: ' + @NoRetryList END);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
