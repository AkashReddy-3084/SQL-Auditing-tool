-- Checklist: ETL windows avoid contention with reporting/query workloads
-- Scope: SERVER
-- Scoring: 3 = every enabled job schedule starts outside 07:00-19:00 and does not repeat intraday; 2 = 75% or more do, or Azure SQL Database where scheduling is external; 1 = fewer than 75% do but some run off peak; 0 = no enabled schedule runs off peak or no schedule metadata exists

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'SQL Agent schedule metadata could not be read';
DECLARE @Engine INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Schedules INT = 0;
DECLARE @OffPeak INT = 0;
DECLARE @PeakList NVARCHAR(MAX) = '';
DECLARE @ProbeError NVARCHAR(400) = '';
DECLARE @Ratio DECIMAL(9, 4) = 0;
DECLARE @Sql NVARCHAR(MAX);

IF @Engine = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database (EngineEdition 5): SQL Agent schedules do not exist on this engine, so the ETL window is driven by an external orchestrator (Data Factory / Elastic Jobs) whose timing is not readable from the instance.';
END
ELSE
BEGIN
    BEGIN TRY
        SET @Sql = N'
SELECT @cnt = COUNT(*),
       @off = ISNULL(SUM(CASE WHEN s.freq_subday_type <= 1
                               AND (s.active_start_time < 70000 OR s.active_start_time >= 190000)
                              THEN 1 ELSE 0 END), 0),
       @lst = ISNULL(LEFT(STRING_AGG(CASE WHEN s.freq_subday_type <= 1
                               AND (s.active_start_time < 70000 OR s.active_start_time >= 190000)
                              THEN NULL
                              ELSE CONVERT(NVARCHAR(MAX), CONCAT(j.name, N'' starts '',
                                   RIGHT(CONCAT(N''000000'', s.active_start_time), 6))) END, N'', ''), 400), N'''')
FROM msdb.dbo.sysschedules AS s
JOIN msdb.dbo.sysjobschedules AS sj ON sj.schedule_id = s.schedule_id
JOIN msdb.dbo.sysjobs AS j ON j.job_id = sj.job_id
WHERE s.enabled = 1 AND j.enabled = 1;';
        EXEC sys.sp_executesql @Sql,
             N'@cnt INT OUTPUT, @off INT OUTPUT, @lst NVARCHAR(MAX) OUTPUT',
             @cnt = @Schedules OUTPUT, @off = @OffPeak OUTPUT, @lst = @PeakList OUTPUT;
    END TRY
    BEGIN CATCH
        SET @ProbeError = ERROR_MESSAGE();
    END CATCH

    SET @Ratio = CASE WHEN @Schedules = 0 THEN 0
                      ELSE CONVERT(DECIMAL(9, 4), @OffPeak) / @Schedules END;

    IF @Schedules > 0 AND @OffPeak = @Schedules
        SET @Score = 3;
    ELSE IF @Schedules > 0 AND @Ratio >= 0.75
        SET @Score = 2;
    ELSE IF @OffPeak > 0
        SET @Score = 1;
    ELSE
        SET @Score = 0;

    SET @Finding = CONCAT('Enabled schedules attached to enabled Agent jobs = ', @Schedules,
        '; schedules starting outside the 07:00-19:00 reporting window with no intraday repetition = ', @OffPeak,
        CASE WHEN LEN(ISNULL(@PeakList, '')) > 0
             THEN CONCAT('. Schedules overlapping the reporting window: ', @PeakList)
             ELSE '. No enabled schedule overlaps the reporting window' END, '.',
        CASE WHEN LEN(@ProbeError) > 0 THEN CONCAT(' Agent metadata probe error: ', @ProbeError) ELSE '' END);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
