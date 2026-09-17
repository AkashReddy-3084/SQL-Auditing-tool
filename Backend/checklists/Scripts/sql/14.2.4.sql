SET NOCOUNT ON;

DECLARE @Result nvarchar(20);
DECLARE @Score int;
DECLARE @DatabaseQueried nvarchar(128) = N'msdb';
DECLARE @Finding nvarchar(2000);
DECLARE @MatchingJobCount int;
DECLARE @AutomatedJobCount int;

;WITH FragmentationSteps AS
(
    SELECT DISTINCT
        j.job_id,
        j.enabled AS JobEnabled
    FROM msdb.dbo.sysjobs AS j
    INNER JOIN msdb.dbo.sysjobsteps AS js
        ON js.job_id = j.job_id
    WHERE
        (
            LOWER(js.command) LIKE N'%sys.dm_db_index_physical_stats%'
            AND
            (
                LOWER(js.command) LIKE N'%alter index%rebuild%'
                OR LOWER(js.command) LIKE N'%alter index%reorganize%'
            )
        )
        OR
        (
            LOWER(js.command) LIKE N'%indexoptimize%'
            AND
            (
                LOWER(js.command) LIKE N'%@fragmentationlow%'
                OR LOWER(js.command) LIKE N'%@fragmentationmedium%'
                OR LOWER(js.command) LIKE N'%@fragmentationhigh%'
            )
        )
),
JobEvidence AS
(
    SELECT
        fs.job_id,
        fs.JobEnabled,
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM msdb.dbo.sysjobschedules AS jsch
            INNER JOIN msdb.dbo.sysschedules AS sch
                ON sch.schedule_id = jsch.schedule_id
            WHERE jsch.job_id = fs.job_id
              AND sch.enabled = 1
        ) THEN 1 ELSE 0 END AS HasEnabledSchedule
    FROM FragmentationSteps AS fs
)
SELECT
    @MatchingJobCount = COUNT(*),
    @AutomatedJobCount = COALESCE(SUM(CASE WHEN JobEnabled = 1 AND HasEnabledSchedule = 1 THEN 1 ELSE 0 END), 0)
FROM JobEvidence;

IF @AutomatedJobCount > 0
BEGIN
    SET @Score = 3;
    SET @Finding = CONCAT(N'Found ', @AutomatedJobCount, N' enabled and scheduled fragmentation-based index maintenance job(s); ', @MatchingJobCount, N' matching job(s) total.');
END
ELSE IF @MatchingJobCount > 0
BEGIN
    SET @Score = 1;
    SET @Finding = CONCAT(N'Found ', @MatchingJobCount, N' fragmentation-based index maintenance job(s), but none are both enabled and attached to an enabled schedule.');
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = N'No SQL Agent job step was found that demonstrably performs fragmentation-based index rebuild or reorganize maintenance.';
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

-- SQL Server Agent does not exist on Azure SQL Database or on Express, so its absence is not
-- evidence that this control is missing - the obligation moves to the external scheduler.
IF (CONVERT(int, SERVERPROPERTY('EngineEdition')) = 5
    OR CONVERT(nvarchar(128), SERVERPROPERTY('Edition')) LIKE 'Express%'
    OR DB_ID('msdb') IS NULL)
BEGIN
    -- NULL score marks this Not Applicable rather than failed.
    SET @Result = 'Not Applicable';
    SET @Score = NULL;
    SET @Finding = N'SQL Server Agent is not available on this edition ('
        + ISNULL(CONVERT(nvarchar(128), SERVERPROPERTY('Edition')), N'unknown')
        + N'), so this control cannot be evidenced inside the database engine. Confirm how it is '
        + N'handled by whatever schedules work outside SQL Server (Windows Task Scheduler, Azure '
        + N'Data Factory, Control-M, Airflow). Engine-side evidence: '
        + ISNULL(@Finding, N'none');
END
SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;