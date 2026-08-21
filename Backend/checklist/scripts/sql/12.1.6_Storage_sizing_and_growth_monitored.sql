-- Checklist: Storage sizing and growth monitored
-- Scope: SERVER
-- Scoring: 0=No monitoring evidence; 1=Disabled jobs/alerts or weak configuration; 2=Enabled jobs/alerts without schedule or Azure SQL fixed growth; 3=Enabled scheduled monitoring jobs/alerts.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @JobEvidence NVARCHAR(MAX) = '';
DECLARE @AlertEvidence NVARCHAR(MAX) = '';
DECLARE @ScheduledEvidence NVARCHAR(MAX) = '';
DECLARE @DisabledEvidence NVARCHAR(MAX) = '';
DECLARE @FileEvidence NVARCHAR(MAX) = '';

SET @DatabaseQueried = 'master';

IF @EngineEdition <> 5
BEGIN
    -- SQL Server / Azure SQL MI
    SELECT @ScheduledEvidence = ISNULL(STRING_AGG(j.name, ', '), '')
    FROM msdb.dbo.sysjobs j
    INNER JOIN msdb.dbo.sysjobschedules js ON j.job_id = js.job_id
    WHERE j.enabled = 1 AND js.enabled = 1
      AND (j.name LIKE '%disk%' OR j.name LIKE '%space%' OR j.name LIKE '%storage%' OR j.name LIKE '%file%' OR j.name LIKE '%growth%' OR j.name LIKE '%capacity%');

    SELECT @JobEvidence = ISNULL(STRING_AGG(j.name, ', '), '')
    FROM msdb.dbo.sysjobs j
    WHERE j.enabled = 1
      AND (j.name LIKE '%disk%' OR j.name LIKE '%space%' OR j.name LIKE '%storage%' OR j.name LIKE '%file%' OR j.name LIKE '%growth%' OR j.name LIKE '%capacity%');

    SELECT @DisabledEvidence = ISNULL(STRING_AGG(j.name, ', '), '')
    FROM msdb.dbo.sysjobs j
    WHERE j.enabled = 0
      AND (j.name LIKE '%disk%' OR j.name LIKE '%space%' OR j.name LIKE '%storage%' OR j.name LIKE '%file%' OR j.name LIKE '%growth%' OR j.name LIKE '%capacity%');

    SELECT @AlertEvidence = ISNULL(STRING_AGG(CONVERT(NVARCHAR(10), event_id), ', '), '')
    FROM msdb.dbo.sysalerts
    WHERE enabled = 1
      AND event_id IN (1105, 9002, 17803);

    IF @ScheduledEvidence <> ''
    BEGIN
        SET @Score = 3;
        SET @Finding = 'Scheduled monitoring jobs found: ' + @ScheduledEvidence;
    END
    ELSE IF @JobEvidence <> '' OR @AlertEvidence <> ''
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Enabled monitoring jobs/alerts found (no schedule): ' + 
            CASE WHEN @JobEvidence <> '' THEN @JobEvidence ELSE '' END +
            CASE WHEN @JobEvidence <> '' AND @AlertEvidence <> '' THEN '; ' ELSE '' END +
            CASE WHEN @AlertEvidence <> '' THEN 'Alerts: ' + @AlertEvidence ELSE '' END;
    END
    ELSE IF @DisabledEvidence <> ''
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Disabled monitoring jobs found: ' + @DisabledEvidence;
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No storage/disk monitoring jobs or alerts found';
    END
END
ELSE
BEGIN
    -- Azure SQL Database
    SELECT @FileEvidence = ISNULL(STRING_AGG(
        QUOTENAME(name) + ': max_size=' + CONVERT(NVARCHAR(20), max_size) + ', is_percent_growth=' + CONVERT(NVARCHAR(10), is_percent_growth),
        ', '
    ), '')
    FROM sys.database_files
    WHERE type IN (0, 1);

    IF EXISTS (SELECT 1 FROM sys.database_files WHERE type IN (0,1) AND max_size > 0 AND is_percent_growth = 0)
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Azure SQL DB: Fixed growth and max_size configured. ' + @FileEvidence + ' -- NOTE: This script provides automated evidence. Full compliance requires human review.';
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Azure SQL DB: Percent growth or unlimited max_size detected. ' + @FileEvidence + ' -- NOTE: This script provides automated evidence. Full compliance requires human review.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;