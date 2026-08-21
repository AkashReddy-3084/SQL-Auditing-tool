-- Checklist: Job failures alert the responsible team
-- Scope: SERVER
-- Scoring: 3=100% of jobs configured, 2=>80% configured, 1=>0% configured, 0=0% configured or no jobs found

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @TotalJobs INT = 0;
DECLARE @ConfiguredJobs INT = 0;
DECLARE @NonCompliantJobs NVARCHAR(MAX) = '';

IF @EngineEdition = 5
BEGIN
    SET @Score = 3;
    SET @Finding = 'Azure SQL Database does not support SQL Server Agent. Job monitoring is handled externally.';
END
ELSE IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    SELECT 
        @TotalJobs = COUNT(*),
        @ConfiguredJobs = SUM(CASE 
            WHEN (notify_level_email IN (2,3) AND notify_email_operator_id > 0) 
              OR (notify_level_netsend IN (2,3) AND notify_netsend_operator_id > 0) 
              OR (notify_level_page IN (2,3) AND notify_page_operator_id > 0)
            THEN 1 ELSE 0 END)
    FROM msdb.dbo.sysjobs;

    IF @TotalJobs > 0
    BEGIN
        SELECT @NonCompliantJobs = STRING_AGG(name, ', ')
        FROM msdb.dbo.sysjobs
        WHERE NOT (
            (notify_level_email IN (2,3) AND notify_email_operator_id > 0) 
            OR (notify_level_netsend IN (2,3) AND notify_netsend_operator_id > 0) 
            OR (notify_level_page IN (2,3) AND notify_page_operator_id > 0)
        );

        DECLARE @Pct FLOAT = CAST(@ConfiguredJobs AS FLOAT) / @TotalJobs * 100.0;

        IF @Pct = 100.0 SET @Score = 3;
        ELSE IF @Pct > 80.0 SET @Score = 2;
        ELSE IF @Pct > 0.0 SET @Score = 1;
        ELSE SET @Score = 0;
    END
    ELSE
    BEGIN
        SET @Score = 3;
        SET @NonCompliantJobs = 'No jobs found';
    END

    IF @Score = 3
        SET @Finding = 'All ' + CAST(@TotalJobs AS NVARCHAR(10)) + ' job(s) are configured to alert on failure.';
    ELSE
        SET @Finding = CAST(@ConfiguredJobs AS NVARCHAR(10)) + ' of ' + CAST(@TotalJobs AS NVARCHAR(10)) + ' job(s) configured. Non-compliant: ' + ISNULL(@NonCompliantJobs, 'None');
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = 'SQL Server Agent metadata (msdb.dbo.sysjobs) is inaccessible.';
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;