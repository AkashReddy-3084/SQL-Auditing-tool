-- Checklist: Corruption detection alerting in place
-- Scope: SERVER
-- Scoring: 3=Active corruption alerts configured; 2=Integrity check jobs enabled but no alerts; 1=Jobs/alerts exist but disabled; 0=No evidence found.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @AlertCount INT = 0;
DECLARE @DisabledAlertCount INT = 0;
DECLARE @JobCount INT = 0;
DECLARE @DisabledJobCount INT = 0;

SET @DatabaseQueried = 'master';

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: Corruption detection is platform-managed via Azure Monitor/Activity Log
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database relies on platform-managed corruption detection and Azure Monitor alerting. T-SQL cannot verify Azure-level alerts.';
END
ELSE IF OBJECT_ID('msdb.dbo.sysalerts') IS NOT NULL
BEGIN
    SELECT @AlertCount = COUNT(*)
    FROM msdb.dbo.sysalerts
    WHERE enabled = 1
      AND (message_id BETWEEN 8900 AND 8999 
         OR severity BETWEEN 10 AND 16 
         OR ISNULL(message_text, '') LIKE '%corruption%');

    SELECT @DisabledAlertCount = COUNT(*)
    FROM msdb.dbo.sysalerts
    WHERE enabled = 0
      AND (message_id BETWEEN 8900 AND 8999 
         OR severity BETWEEN 10 AND 16 
         OR ISNULL(message_text, '') LIKE '%corruption%');

    SELECT @JobCount = COUNT(*)
    FROM msdb.dbo.sysjobs
    WHERE enabled = 1
      AND (name LIKE '%Integrity%' OR name LIKE '%CHECKDB%' OR name LIKE '%DatabaseIntegrityCheck%');

    SELECT @DisabledJobCount = COUNT(*)
    FROM msdb.dbo.sysjobs
    WHERE enabled = 0
      AND (name LIKE '%Integrity%' OR name LIKE '%CHECKDB%' OR name LIKE '%DatabaseIntegrityCheck%');

    IF @AlertCount > 0
    BEGIN
        SET @Score = 3;
        SET @Finding = CAST(@AlertCount AS NVARCHAR) + ' active SQL Agent alert(s) configured for corruption detection.';
    END
    ELSE IF @JobCount > 0
    BEGIN
        SET @Score = 2;
        SET @Finding = CAST(@JobCount AS NVARCHAR) + ' enabled integrity check job(s) found, but no explicit corruption alerts configured.';
    END
    ELSE IF @DisabledJobCount > 0 OR @DisabledAlertCount > 0
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Corruption detection jobs or alerts exist but are currently disabled.';
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No corruption detection alerts or integrity check jobs found.';
    END
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = 'SQL Agent metadata (msdb) is unavailable or inaccessible.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;