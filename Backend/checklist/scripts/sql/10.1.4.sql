-- Checklist: Alerts configured for resource saturation and errors
-- Scope: SERVER
-- Scoring: 3 = 5+ alerts; 2 = 1-4 alerts; 1 = alerts exist but no critical severity coverage; 0 = no alerts

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No alerts configured';

DECLARE @TotalAlerts INT = 0;
DECLARE @CriticalAlerts INT = 0;
DECLARE @AlertList NVARCHAR(MAX) = '';

-- Azure SQL Database does not support SQL Agent Alerts
IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Score = 0;
    SET @Finding = 'Azure SQL Database: SQL Agent alerts are not supported; monitoring is managed via Azure Monitor';
END
ELSE
BEGIN
    -- Use dynamic SQL to handle STRING_AGG for version compatibility (SQL 2017+)
    -- and to avoid parsing errors on older versions.
    DECLARE @Sql NVARCHAR(MAX) = N'
    SELECT 
        @TotalAlerts = COUNT(*),
        @CriticalAlerts = SUM(CASE WHEN event_method = 1 AND (severity >= 17) THEN 1 ELSE 0 END),
        @AlertList = (
            SELECT STRING_AGG(CAST(name AS NVARCHAR(MAX)), '', '') 
            FROM msdb.dbo.sysalerts
        )
    FROM msdb.dbo.sysalerts;';

    -- For versions < 2017, STRING_AGG will fail. We use a compatible approach.
    IF (SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS INT)) < 14
    BEGIN
        SET @Sql = N'
        SELECT 
            @TotalAlerts = COUNT(*),
            @CriticalAlerts = SUM(CASE WHEN event_method = 1 AND (severity >= 17) THEN 1 ELSE 0 END),
            @AlertList = STUFF((SELECT '', '' + CAST(name AS NVARCHAR(MAX)) 
                               FROM msdb.dbo.sysalerts 
                               FOR XML PATH('''')), 1, 2, '''')
        FROM msdb.dbo.sysalerts;';
    END

    EXEC sp_executesql @Sql, 
        N'@TotalAlerts INT OUTPUT, @CriticalAlerts INT OUTPUT, @AlertList NVARCHAR(MAX) OUTPUT', 
        @TotalAlerts = @TotalAlerts OUTPUT, @CriticalAlerts = @CriticalAlerts OUTPUT, @AlertList = @AlertList OUTPUT;

    IF ISNULL(@TotalAlerts, 0) = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No SQL Agent alerts configured';
    END
    ELSE IF ISNULL(@CriticalAlerts, 0) = 0
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Alerts exist, but none cover critical severity levels (17-25): ' + ISNULL(@AlertList, 'None');
    END
    ELSE
    BEGIN
        IF @TotalAlerts >= 5
            SET @Score = 3;
        ELSE
            SET @Score = 2;
            
        SET @Finding = 'Configured alerts (' + CAST(@TotalAlerts AS NVARCHAR(10)) + ' total, ' + CAST(@CriticalAlerts AS NVARCHAR(10)) + ' critical): ' + ISNULL(@AlertList, 'None');
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;