-- Checklist: Error/severity alerts configured (Agent alerts or equivalent)
-- Scope: SERVER
-- Scoring: 3 = 5+ alerts; 2 = 1-4 alerts; 1 = alerts exist but no operators; 0 = no alerts

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No alerts configured';

DECLARE @AlertCount INT = 0;
DECLARE @OperatorCount INT = 0;
DECLARE @AlertList NVARCHAR(MAX) = '';

-- Azure SQL Database does not support SQL Agent Alerts
IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database: SQL Agent Alerts are not applicable; monitoring is handled by Azure Monitor/Alerts';
END
ELSE
BEGIN
    -- Count total alerts
    SELECT @AlertCount = COUNT(*) 
    FROM msdb.dbo.sysalerts;

    -- Count unique operators assigned to any alert
    SELECT @OperatorCount = COUNT(DISTINCT operator_id) 
    FROM msdb.dbo.sysalerts 
    WHERE operator_id IS NOT NULL;

    -- Build list of alerts
    SELECT @AlertList = STRING_AGG(CAST(name AS NVARCHAR(MAX)), ', ') 
    FROM msdb.dbo.sysalerts;

    IF @AlertCount >= 5
    BEGIN
        SET @Score = 3;
        SET @Finding = 'Configured alerts (' + CAST(@AlertCount AS NVARCHAR(10)) + '): ' + ISNULL(@AlertList, 'None');
    END
    ELSE IF @AlertCount > 0 AND @OperatorCount > 0
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Configured alerts (' + CAST(@AlertCount AS NVARCHAR(10)) + '): ' + ISNULL(@AlertList, 'None');
    END
    ELSE IF @AlertCount > 0 AND @OperatorCount = 0
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Alerts exist (' + CAST(@AlertCount AS NVARCHAR(10)) + ') but no operators are assigned to them';
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No SQL Agent alerts configured in msdb.dbo.sysalerts';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;