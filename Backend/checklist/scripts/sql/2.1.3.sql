-- Checklist: ETL is parameterized (no hardcoded servers, paths, dates, or credentials)
-- Scope: SERVER
-- Scoring: 3 = no Agent job step embeds a server, path, date or credential literal; 2 = under 5% of steps do, or the platform exposes no Agent metadata; 1 = under 25% of steps do; 0 = 25% or more do, or no job steps exist

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'ETL parameterization evidence was unavailable';
DECLARE @Engine INT = ISNULL(CONVERT(INT, SERVERPROPERTY('EngineEdition')), 0);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Steps INT = 0;
DECLARE @Bad INT = 0;
DECLARE @BadPct DECIMAL(6, 2) = 0;
DECLARE @BadJobs NVARCHAR(MAX) = '';
DECLARE @ReadError BIT = 0;

CREATE TABLE #JobStep (JobName NVARCHAR(256) NOT NULL, IsHardCoded INT NOT NULL);

IF @Engine <> 5
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT j.name, CASE WHEN s.command LIKE N''%\\%'' OR s.command LIKE N''%[A-Za-z]:\%'' OR s.command LIKE N''%password=%'' OR s.command LIKE N''%pwd=%'' OR s.command LIKE N''%data source=%'' OR s.command LIKE N''%server=%'' OR s.command LIKE N''%[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%'' THEN 1 ELSE 0 END FROM msdb.dbo.sysjobsteps AS s INNER JOIN msdb.dbo.sysjobs AS j ON j.job_id = s.job_id;';
        INSERT INTO #JobStep (JobName, IsHardCoded) EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        SET @ReadError = 1;
    END CATCH
END

SELECT @Steps = COUNT(*),
       @Bad = ISNULL(SUM(s.IsHardCoded), 0)
FROM #JobStep AS s;

SELECT @BadJobs = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), x.JobName), ', '), 400), '')
FROM (SELECT DISTINCT js.JobName FROM #JobStep AS js WHERE js.IsHardCoded = 1) AS x;

SET @BadPct = CASE WHEN @Steps = 0 THEN 0
                   ELSE CONVERT(DECIMAL(6, 2), 100.0 * @Bad / NULLIF(@Steps, 0)) END;

IF @Engine = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database exposes no SQL Agent job step command text; ETL parameter binding is held in the external orchestration service and cannot be read on the instance';
END
ELSE IF @Steps = 0
BEGIN
    SET @Score = 0;
    SET @Finding = CONCAT('No SQL Agent job steps exist on this instance, so no ETL command text could be inspected for hardcoded values',
                          CASE WHEN @ReadError = 1 THEN '; job step metadata could not be read' ELSE '' END);
END
ELSE
BEGIN
    SET @Score = CASE WHEN @Bad = 0 THEN 3
                      WHEN @BadPct < 5 THEN 2
                      WHEN @BadPct < 25 THEN 1
                      ELSE 0 END;
    SET @Finding = CONCAT('Agent job steps inspected = ', @Steps,
                          '; steps whose command text embeds a UNC or drive path, a connection or credential literal, or a literal date = ', @Bad,
                          ' (', @BadPct, '%)',
                          CASE WHEN @Bad = 0 THEN '; no hardcoded values found in any job step'
                               ELSE '; jobs affected: ' + @BadJobs END);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
