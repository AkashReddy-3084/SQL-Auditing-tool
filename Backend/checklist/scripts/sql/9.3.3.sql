-- Checklist: Corruption detection alerting in place
-- Scope: SERVER
-- Scoring: 2 = severity-24 alerts and suspect-page evidence are both available; 1 = one corruption indicator exists; 0 = no corruption detection evidence
-- NOTE: Automated evidence only; alert routing and incident response require human review.

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'Corruption detection metadata could not be evaluated';
DECLARE @Severity24Alerts INT = 0;
DECLARE @SuspectPages INT = 0;

BEGIN TRY
    SELECT @Severity24Alerts = COUNT(*) FROM msdb.dbo.sysalerts WHERE severity = 24;
    SELECT @SuspectPages = COUNT(*) FROM msdb.dbo.suspect_pages;
    SET @Score = CASE WHEN @Severity24Alerts > 0 AND @SuspectPages > 0 THEN 2 WHEN @Severity24Alerts > 0 OR @SuspectPages > 0 THEN 1 ELSE 0 END;
    SET @Finding = N'severity24_alerts=' + CONVERT(NVARCHAR(20), @Severity24Alerts) + N', suspect_pages=' + CONVERT(NVARCHAR(20), @SuspectPages);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read corruption detection metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;