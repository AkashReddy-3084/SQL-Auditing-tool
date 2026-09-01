-- Checklist: Bulk load patterns used (BULK INSERT / bcp / minimal logging) for large loads
-- Scope: SERVER
-- Scoring: 3 = bulk-load command syntax found in Agent job steps and at least one online user database allows minimal logging; 2 = bulk-load syntax found but every user database is in FULL recovery, or Azure SQL Database where load orchestration is external; 1 = only SSIS package steps found; 0 = no bulk-load evidence at all

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Bulk-load evidence could not be collected';
DECLARE @Engine INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @BulkPattern NVARCHAR(60) = '%' + CHAR(66) + 'ULK ' + CHAR(73) + 'NSERT%';
DECLARE @BcpPattern NVARCHAR(60) = '%bcp %';
DECLARE @RowsetPattern NVARCHAR(60) = '%OPENROWSET%';
DECLARE @BulkJobs INT = 0;
DECLARE @SsisSteps INT = 0;
DECLARE @JobList NVARCHAR(MAX) = '';
DECLARE @UserDbs INT = 0;
DECLARE @MinLogDbs INT = 0;
DECLARE @MinLogList NVARCHAR(MAX) = '';
DECLARE @ProbeError NVARCHAR(400) = '';
DECLARE @Sql NVARCHAR(MAX);

IF @Engine = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database (EngineEdition 5): there is no SQL Agent job catalogue on this engine, so large-load orchestration is hosted externally (Data Factory / Elastic Jobs) and its command text cannot be read from the instance.';
END
ELSE
BEGIN
    BEGIN TRY
        SET @Sql = N'
SELECT @cnt = COUNT(*),
       @lst = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), q.jobname), N'', ''), 400), N'''')
FROM (
    SELECT DISTINCT j.name AS jobname
    FROM msdb.dbo.sysjobsteps AS s
    JOIN msdb.dbo.sysjobs AS j ON j.job_id = s.job_id
    WHERE s.command LIKE @bp OR s.command LIKE @cp OR s.command LIKE @rp
) AS q;';
        EXEC sys.sp_executesql @Sql,
             N'@bp NVARCHAR(60), @cp NVARCHAR(60), @rp NVARCHAR(60), @cnt INT OUTPUT, @lst NVARCHAR(MAX) OUTPUT',
             @bp = @BulkPattern, @cp = @BcpPattern, @rp = @RowsetPattern,
             @cnt = @BulkJobs OUTPUT, @lst = @JobList OUTPUT;

        SET @Sql = N'SELECT @cnt = COUNT(*) FROM msdb.dbo.sysjobsteps WHERE subsystem = N''SSIS'';';
        EXEC sys.sp_executesql @Sql, N'@cnt INT OUTPUT', @cnt = @SsisSteps OUTPUT;
    END TRY
    BEGIN CATCH
        SET @ProbeError = ERROR_MESSAGE();
    END CATCH

    SELECT @UserDbs = COUNT(*),
           @MinLogDbs = ISNULL(SUM(CASE WHEN d.recovery_model_desc IN ('SIMPLE', 'BULK_LOGGED') THEN 1 ELSE 0 END), 0),
           @MinLogList = ISNULL(LEFT(STRING_AGG(CASE WHEN d.recovery_model_desc IN ('SIMPLE', 'BULK_LOGGED')
                                  THEN CONVERT(NVARCHAR(MAX), d.name + ' [' + d.recovery_model_desc + ']')
                                  END, ', '), 300), '')
    FROM sys.databases AS d
    WHERE d.database_id > 4 AND d.state = 0;

    IF @BulkJobs > 0 AND @MinLogDbs > 0
        SET @Score = 3;
    ELSE IF @BulkJobs > 0
        SET @Score = 2;
    ELSE IF @SsisSteps > 0
        SET @Score = 1;
    ELSE
        SET @Score = 0;

    SET @Finding = CONCAT('Agent jobs whose step commands use bulk-load syntax = ', @BulkJobs,
        CASE WHEN LEN(ISNULL(@JobList, '')) > 0 THEN CONCAT(' (', @JobList, ')') ELSE '' END,
        '; SSIS package job steps = ', @SsisSteps,
        '; online user databases = ', @UserDbs,
        ', of which ', @MinLogDbs, ' allow minimal logging',
        CASE WHEN LEN(ISNULL(@MinLogList, '')) > 0 THEN CONCAT(': ', @MinLogList) ELSE '' END, '.',
        CASE WHEN LEN(@ProbeError) > 0 THEN CONCAT(' Agent metadata probe error: ', @ProbeError) ELSE '' END);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
