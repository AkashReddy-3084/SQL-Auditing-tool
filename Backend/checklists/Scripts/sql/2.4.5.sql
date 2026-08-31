SET NOCOUNT ON;

DECLARE @Score INT;
DECLARE @Result NVARCHAR(20);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(128) = N'ssisdb, msdb';

DECLARE @SsisdbExists BIT = 0;
DECLARE @SsisExecutionCount INT = 0;
DECLARE @SsisDistinctPackages INT = 0;
DECLARE @SsisWithDuration INT = 0;
DECLARE @SsisDistinctDays INT = 0;
DECLARE @SsisAvgDurationSec FLOAT = NULL;
DECLARE @SsisMinDurationSec FLOAT = NULL;
DECLARE @SsisMaxDurationSec FLOAT = NULL;
DECLARE @SsisPackagesWithMultiRuns INT = 0;

DECLARE @JobHistoryCount INT = 0;
DECLARE @JobDistinctJobs INT = 0;
DECLARE @JobWithDuration INT = 0;
DECLARE @JobDistinctDays INT = 0;
DECLARE @EtlLikeJobCount INT = 0;

IF DB_ID(N'ssisdb') IS NOT NULL
BEGIN
    SET @SsisdbExists = 1;

    BEGIN TRY
        IF OBJECT_ID(N'ssisdb.catalog.executions', N'U') IS NOT NULL
        BEGIN
            SELECT
                @SsisExecutionCount = COUNT(*),
                @SsisDistinctPackages = COUNT(DISTINCT CONCAT(ISNULL(folder_name, N''), N'/', ISNULL(project_name, N''), N'/', ISNULL(package_name, N''))),
                @SsisWithDuration = SUM(CASE WHEN execution_duration IS NOT NULL AND execution_duration >= 0 THEN 1 ELSE 0 END),
                @SsisDistinctDays = COUNT(DISTINCT CONVERT(date, created_time)),
                @SsisAvgDurationSec = AVG(CASE WHEN execution_duration IS NOT NULL AND execution_duration >= 0 THEN CONVERT(FLOAT, execution_duration) / 1000.0 END),
                @SsisMinDurationSec = MIN(CASE WHEN execution_duration IS NOT NULL AND execution_duration >= 0 THEN CONVERT(FLOAT, execution_duration) / 1000.0 END),
                @SsisMaxDurationSec = MAX(CASE WHEN execution_duration IS NOT NULL AND execution_duration >= 0 THEN CONVERT(FLOAT, execution_duration) / 1000.0 END)
            FROM ssisdb.catalog.executions
            WHERE created_time >= DATEADD(DAY, -90, SYSUTCDATETIME());

            ;WITH pkg AS (
                SELECT
                    CONCAT(ISNULL(folder_name, N''), N'/', ISNULL(project_name, N''), N'/', ISNULL(package_name, N'')) AS pkg_key,
                    COUNT(*) AS run_cnt
                FROM ssisdb.catalog.executions
                WHERE created_time >= DATEADD(DAY, -90, SYSUTCDATETIME())
                  AND execution_duration IS NOT NULL
                  AND execution_duration >= 0
                GROUP BY CONCAT(ISNULL(folder_name, N''), N'/', ISNULL(project_name, N''), N'/', ISNULL(package_name, N''))
            )
            SELECT @SsisPackagesWithMultiRuns = COUNT(*)
            FROM pkg
            WHERE run_cnt >= 3;
        END
    END TRY
    BEGIN CATCH
        SET @SsisExecutionCount = ISNULL(@SsisExecutionCount, 0);
    END CATCH
END

BEGIN TRY
    IF OBJECT_ID(N'msdb.dbo.sysjobs', N'U') IS NOT NULL
       AND OBJECT_ID(N'msdb.dbo.sysjobhistory', N'U') IS NOT NULL
    BEGIN
        ;WITH etl_jobs AS (
            SELECT j.job_id, j.name
            FROM msdb.dbo.sysjobs j
            WHERE j.name LIKE N'%ETL%'
               OR j.name LIKE N'%SSIS%'
               OR j.name LIKE N'%DTS%'
               OR j.name LIKE N'%Load%'
               OR j.name LIKE N'%Extract%'
               OR j.name LIKE N'%Warehouse%'
               OR j.name LIKE N'%Ingest%'
               OR j.name LIKE N'%Dataflow%'
               OR j.name LIKE N'%Data Flow%'
               OR EXISTS (
                    SELECT 1
                    FROM msdb.dbo.sysjobsteps s
                    WHERE s.job_id = j.job_id
                      AND (
                            s.subsystem IN (N'SSIS', N'SSISPackage', N'CmdExec', N'PowerShell')
                            OR s.command LIKE N'%dtexec%'
                            OR s.command LIKE N'%SSISDB%'
                            OR s.command LIKE N'%.dtsx%'
                            OR s.command LIKE N'%ETL%'
                          )
               )
        ),
        hist AS (
            SELECT
                h.job_id,
                h.run_duration,
                CASE
                    WHEN h.run_date <= 0 THEN NULL
                    ELSE CONVERT(date, CONVERT(char(8), h.run_date), 112)
                END AS run_day
            FROM msdb.dbo.sysjobhistory h
            INNER JOIN etl_jobs e ON e.job_id = h.job_id
            WHERE h.step_id = 0
              AND h.run_date >= CONVERT(int, CONVERT(char(8), DATEADD(DAY, -90, GETDATE()), 112))
        )
        SELECT
            @EtlLikeJobCount = (SELECT COUNT(*) FROM etl_jobs),
            @JobHistoryCount = COUNT(*),
            @JobDistinctJobs = COUNT(DISTINCT job_id),
            @JobWithDuration = SUM(CASE WHEN run_duration IS NOT NULL AND run_duration >= 0 THEN 1 ELSE 0 END),
            @JobDistinctDays = COUNT(DISTINCT run_day)
        FROM hist;
    END
END TRY
BEGIN CATCH
    SET @JobHistoryCount = ISNULL(@JobHistoryCount, 0);
END CATCH

SET @SsisWithDuration = ISNULL(@SsisWithDuration, 0);
SET @SsisExecutionCount = ISNULL(@SsisExecutionCount, 0);
SET @SsisDistinctPackages = ISNULL(@SsisDistinctPackages, 0);
SET @SsisDistinctDays = ISNULL(@SsisDistinctDays, 0);
SET @SsisPackagesWithMultiRuns = ISNULL(@SsisPackagesWithMultiRuns, 0);
SET @JobHistoryCount = ISNULL(@JobHistoryCount, 0);
SET @JobDistinctJobs = ISNULL(@JobDistinctJobs, 0);
SET @JobWithDuration = ISNULL(@JobWithDuration, 0);
SET @JobDistinctDays = ISNULL(@JobDistinctDays, 0);
SET @EtlLikeJobCount = ISNULL(@EtlLikeJobCount, 0);

DECLARE @HasStrongSsis BIT = 0;
DECLARE @HasPartialSsis BIT = 0;
DECLARE @HasStrongJobs BIT = 0;
DECLARE @HasPartialJobs BIT = 0;

IF @SsisWithDuration >= 20 AND @SsisPackagesWithMultiRuns >= 1 AND @SsisDistinctDays >= 7
    SET @HasStrongSsis = 1;
ELSE IF @SsisWithDuration >= 5 AND @SsisDistinctPackages >= 1
    SET @HasPartialSsis = 1;

IF @JobWithDuration >= 20 AND @JobDistinctJobs >= 1 AND @JobDistinctDays >= 7
    SET @HasStrongJobs = 1;
ELSE IF @JobWithDuration >= 5 AND @EtlLikeJobCount >= 1
    SET @HasPartialJobs = 1;

IF @HasStrongSsis = 1 OR @HasStrongJobs = 1
    SET @Score = 3;
ELSE IF @HasPartialSsis = 1 OR @HasPartialJobs = 1
    SET @Score = 2;
ELSE IF @SsisdbExists = 1 OR @EtlLikeJobCount > 0 OR @SsisExecutionCount > 0
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding =
    N'SSISDB present=' + CASE WHEN @SsisdbExists = 1 THEN N'Y' ELSE N'N' END
    + N'; SSIS executions(90d)=' + CONVERT(NVARCHAR(20), @SsisExecutionCount)
    + N', with duration=' + CONVERT(NVARCHAR(20), @SsisWithDuration)
    + N', packages=' + CONVERT(NVARCHAR(20), @SsisDistinctPackages)
    + N', packages with >=3 timed runs=' + CONVERT(NVARCHAR(20), @SsisPackagesWithMultiRuns)
    + N', distinct days=' + CONVERT(NVARCHAR(20), @SsisDistinctDays)
    + CASE
          WHEN @SsisAvgDurationSec IS NOT NULL THEN
              N', duration sec avg/min/max='
              + CONVERT(NVARCHAR(20), CONVERT(DECIMAL(18,2), @SsisAvgDurationSec)) + N'/'
              + CONVERT(NVARCHAR(20), CONVERT(DECIMAL(18,2), @SsisMinDurationSec)) + N'/'
              + CONVERT(NVARCHAR(20), CONVERT(DECIMAL(18,2), @SsisMaxDurationSec))
          ELSE N''
      END
    + N'; ETL-like Agent jobs=' + CONVERT(NVARCHAR(20), @EtlLikeJobCount)
    + N', job outcome rows(90d)=' + CONVERT(NVARCHAR(20), @JobHistoryCount)
    + N', with run_duration=' + CONVERT(NVARCHAR(20), @JobWithDuration)
    + N', distinct jobs/days='
    + CONVERT(NVARCHAR(20), @JobDistinctJobs) + N'/'
    + CONVERT(NVARCHAR(20), @JobDistinctDays)
    + N'. '
    + CASE @Score
          WHEN 3 THEN N'Sufficient multi-run duration history exists to monitor ETL execution times and establish runtime baselines.'
          WHEN 2 THEN N'Some ETL duration history exists, but coverage is limited for robust baselining.'
          WHEN 1 THEN N'ETL-related objects were found, yet little or no usable execution-duration history is available.'
          ELSE N'No SSISDB/Agent ETL execution-duration telemetry was found for monitoring or baselining.'
      END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;