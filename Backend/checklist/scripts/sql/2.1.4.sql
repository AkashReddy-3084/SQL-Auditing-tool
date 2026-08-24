SET NOCOUNT ON;

DECLARE @Result          varchar(10);
DECLARE @Score           int;
DECLARE @DatabaseQueried nvarchar(256);
DECLARE @Finding         nvarchar(max);

DECLARE @EngineEdition int =
    CAST(SERVERPROPERTY('EngineEdition') AS int);

DECLARE @JobCount            int = 0;
DECLARE @EnabledJobCount     int = 0;
DECLARE @ScheduledJobCount   int = 0;
DECLARE @MultiStepJobCount   int = 0;
DECLARE @SsisDbExists        bit = 0;
DECLARE @SsisProjectCount    int = 0;
DECLARE @SsisPackageCount    int = 0;
DECLARE @MasterPackageCount  int = 0;

IF @EngineEdition = 5
BEGIN
    SET @DatabaseQueried = ISNULL(DB_NAME(), N'None');
    SET @Score = 0;
    SET @Finding = N'Azure SQL Database does not host SQL Agent or SSISDB; T-SQL cannot verify master package/pipeline/scheduler orchestration on this engine.';
END
ELSE
BEGIN
    SET @DatabaseQueried = N'msdb';

    IF DB_ID(N'msdb') IS NOT NULL
    BEGIN
        SELECT
            @JobCount = COUNT(*),
            @EnabledJobCount = ISNULL(SUM(CASE WHEN j.enabled = 1 THEN 1 ELSE 0 END), 0)
        FROM msdb.dbo.sysjobs AS j;

        SELECT @ScheduledJobCount = COUNT(DISTINCT j.job_id)
        FROM msdb.dbo.sysjobs AS j
        INNER JOIN msdb.dbo.sysjobschedules AS js
            ON js.job_id = j.job_id
        INNER JOIN msdb.dbo.sysschedules AS s
            ON s.schedule_id = js.schedule_id
        WHERE j.enabled = 1
          AND s.enabled = 1;

        SELECT @MultiStepJobCount = COUNT(*)
        FROM (
            SELECT js.job_id
            FROM msdb.dbo.sysjobsteps AS js
            INNER JOIN msdb.dbo.sysjobs AS j
                ON j.job_id = js.job_id
            WHERE j.enabled = 1
            GROUP BY js.job_id
            HAVING COUNT(*) > 1
        ) AS multi_step_jobs;
    END

    IF DB_ID(N'SSISDB') IS NOT NULL
    BEGIN
        SET @SsisDbExists = 1;
        SET @DatabaseQueried = N'msdb, SSISDB';

        SELECT @SsisProjectCount = COUNT(*)
        FROM SSISDB.catalog.projects;

        SELECT @SsisPackageCount = COUNT(*)
        FROM SSISDB.catalog.packages;

        SELECT @MasterPackageCount = COUNT(*)
        FROM SSISDB.catalog.packages AS p
        WHERE LOWER(p.name) LIKE N'%master%'
           OR LOWER(p.name) LIKE N'%orch%'
           OR LOWER(p.name) LIKE N'%control%'
           OR LOWER(p.name) LIKE N'%parent%'
           OR LOWER(p.name) LIKE N'%main%';
    END

    IF (
            @ScheduledJobCount >= 3
            AND @MultiStepJobCount >= 2
        )
        OR (
            @SsisProjectCount >= 1
            AND @SsisPackageCount >= 2
            AND @MasterPackageCount >= 1
        )
        OR (
            @ScheduledJobCount >= 1
            AND @MultiStepJobCount >= 1
            AND @SsisPackageCount >= 2
        )
        SET @Score = 3;
    ELSE IF (
            @ScheduledJobCount >= 1
            AND @MultiStepJobCount >= 1
        )
        OR @SsisPackageCount >= 2
        OR @ScheduledJobCount >= 2
        SET @Score = 2;
    ELSE IF @JobCount >= 1 OR @SsisPackageCount >= 1
        SET @Score = 1;
    ELSE
        SET @Score = 0;

    SET @Finding =
        N'SQL Agent jobs=' + CAST(ISNULL(@JobCount, 0) AS nvarchar(20))
        + N', enabled=' + CAST(ISNULL(@EnabledJobCount, 0) AS nvarchar(20))
        + N', scheduled_enabled=' + CAST(ISNULL(@ScheduledJobCount, 0) AS nvarchar(20))
        + N', multi_step_enabled=' + CAST(ISNULL(@MultiStepJobCount, 0) AS nvarchar(20))
        + N'; SSISDB=' + CASE WHEN @SsisDbExists = 1 THEN N'yes' ELSE N'no' END
        + N', projects=' + CAST(ISNULL(@SsisProjectCount, 0) AS nvarchar(20))
        + N', packages=' + CAST(ISNULL(@SsisPackageCount, 0) AS nvarchar(20))
        + N', master_like_packages=' + CAST(ISNULL(@MasterPackageCount, 0) AS nvarchar(20))
        + N'.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;