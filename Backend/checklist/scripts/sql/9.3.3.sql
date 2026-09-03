-- Checklist: Corruption detection alerting in place
-- Scope: SERVER
-- Scoring: 3 = severity-24 or 823/824/825 alerting routed to an enabled operator, CHECKSUM page verification on every online user database and no unresolved suspect pages, or platform-managed on Azure SQL Database; 2 = corruption alerting present together with a consistency-check job or full CHECKSUM coverage; 1 = a single weak indicator only; 0 = no corruption detection evidence

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Corruption detection evidence was unavailable';
DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @CheckPattern NVARCHAR(60) = '%' + CHAR(67) + 'HECKDB%';
DECLARE @Sql NVARCHAR(MAX);
DECLARE @SevAlerts INT = 0;
DECLARE @Sev24Alerts INT = 0;
DECLARE @ErrorAlerts INT = 0;
DECLARE @AlertsToOperator INT = 0;
DECLARE @SuspectPages INT = 0;
DECLARE @CheckJobs INT = 0;
DECLARE @CheckJobFailures INT = 0;
DECLARE @NonChecksumDbs INT = 0;
DECLARE @OnlineDbs INT = 0;
DECLARE @ReadNote NVARCHAR(300) = '';
DECLARE @M TABLE (K NVARCHAR(40), V INT NULL);

IF @Edition = 5
BEGIN
    SET @Score = 3;
    SET @Finding = 'Azure SQL Database (EngineEdition 5): page checksums are enforced, integrity checks run continuously and detected page corruption is raised and auto-repaired by the platform; SQL Agent alerts and suspect_pages do not exist in this deployment model.';
END
ELSE
BEGIN
    SET @Sql = N'
SELECT ''SevAlerts'', COUNT(*) FROM msdb.dbo.sysalerts WHERE enabled = 1 AND severity BETWEEN 19 AND 25
UNION ALL SELECT ''Sev24Alerts'', COUNT(*) FROM msdb.dbo.sysalerts WHERE enabled = 1 AND severity = 24
UNION ALL SELECT ''ErrorAlerts'', COUNT(*) FROM msdb.dbo.sysalerts WHERE enabled = 1 AND message_id IN (823, 824, 825)
UNION ALL SELECT ''AlertsToOperator'', COUNT(DISTINCT a.id) FROM msdb.dbo.sysalerts AS a INNER JOIN msdb.dbo.sysnotifications AS n ON n.alert_id = a.id INNER JOIN msdb.dbo.sysoperators AS o ON o.id = n.operator_id WHERE a.enabled = 1 AND o.enabled = 1 AND (a.severity IN (19, 20, 21, 22, 23, 24, 25) OR a.message_id IN (823, 824, 825))
UNION ALL SELECT ''SuspectPages'', COUNT(*) FROM msdb.dbo.suspect_pages WHERE event_type IN (1, 2, 3)
UNION ALL SELECT ''CheckJobs'', COUNT(*) FROM msdb.dbo.sysjobs AS j WHERE j.enabled = 1 AND (j.name LIKE ''%integrity%'' OR j.name LIKE ''%consistency%'' OR EXISTS (SELECT 1 FROM msdb.dbo.sysjobsteps AS s WHERE s.job_id = j.job_id AND s.command LIKE @p))
UNION ALL SELECT ''CheckJobFailures'', COUNT(*) FROM msdb.dbo.sysjobs AS j INNER JOIN msdb.dbo.sysjobhistory AS h ON h.job_id = j.job_id AND h.step_id = 0 WHERE j.enabled = 1 AND h.run_status <> 1 AND (j.name LIKE ''%integrity%'' OR EXISTS (SELECT 1 FROM msdb.dbo.sysjobsteps AS s WHERE s.job_id = j.job_id AND s.command LIKE @p))
UNION ALL SELECT ''NonChecksumDbs'', COUNT(*) FROM sys.databases WHERE database_id > 4 AND state = 0 AND page_verify_option <> 2
UNION ALL SELECT ''OnlineDbs'', COUNT(*) FROM sys.databases WHERE database_id > 4 AND state = 0';

    BEGIN TRY
        INSERT INTO @M (K, V) EXEC sp_executesql @Sql, N'@p NVARCHAR(60)', @p = @CheckPattern;
    END TRY
    BEGIN CATCH
        SET @ReadNote = ' One or more corruption detection sources could not be read: ' + LEFT(ISNULL(ERROR_MESSAGE(), ''), 150) + '.';
    END CATCH;

    SELECT @SevAlerts = ISNULL(MAX(CASE WHEN K = 'SevAlerts' THEN V END), 0),
           @Sev24Alerts = ISNULL(MAX(CASE WHEN K = 'Sev24Alerts' THEN V END), 0),
           @ErrorAlerts = ISNULL(MAX(CASE WHEN K = 'ErrorAlerts' THEN V END), 0),
           @AlertsToOperator = ISNULL(MAX(CASE WHEN K = 'AlertsToOperator' THEN V END), 0),
           @SuspectPages = ISNULL(MAX(CASE WHEN K = 'SuspectPages' THEN V END), 0),
           @CheckJobs = ISNULL(MAX(CASE WHEN K = 'CheckJobs' THEN V END), 0),
           @CheckJobFailures = ISNULL(MAX(CASE WHEN K = 'CheckJobFailures' THEN V END), 0),
           @NonChecksumDbs = ISNULL(MAX(CASE WHEN K = 'NonChecksumDbs' THEN V END), 0),
           @OnlineDbs = ISNULL(MAX(CASE WHEN K = 'OnlineDbs' THEN V END), 0)
    FROM @M;

    SET @Score = CASE
        WHEN (@Sev24Alerts > 0 OR @ErrorAlerts > 0) AND @AlertsToOperator > 0
             AND @NonChecksumDbs = 0 AND @SuspectPages = 0 THEN 3
        WHEN (@Sev24Alerts > 0 OR @ErrorAlerts > 0 OR @SevAlerts > 0)
             AND (@CheckJobs > 0 OR @NonChecksumDbs = 0) THEN 2
        WHEN @SevAlerts > 0 OR @ErrorAlerts > 0 OR @CheckJobs > 0 THEN 1
        ELSE 0
    END;

    SET @Finding = CONCAT(
        'Enabled alerts: severity 19-25 = ', @SevAlerts, ', severity 24 = ', @Sev24Alerts,
        ', error 823/824/825 = ', @ErrorAlerts,
        '; corruption alerts routed to an enabled operator = ', @AlertsToOperator,
        '; unresolved rows in suspect_pages = ', @SuspectPages,
        '; enabled consistency-check jobs = ', @CheckJobs, ' with ', @CheckJobFailures, ' failed run(s)',
        '; online user databases = ', @OnlineDbs, ', of which ', @NonChecksumDbs,
        ' do not use CHECKSUM page verification.',
        @ReadNote);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;