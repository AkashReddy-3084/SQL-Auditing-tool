-- Checklist: Long-running/blocking query alerting configured
-- Scope: SERVER
-- Scoring: 3 = blocked-process threshold set plus an alert or Extended Events session that captures blocking/long duration; 2 = one alerting mechanism present, or platform blocking detection with no in-engine artifact; 1 = only the threshold is set, nothing consumes it; 0 = no evidence

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No long-running or blocking query alerting evidence found';
DECLARE @Engine INT = ISNULL(CONVERT(INT, SERVERPROPERTY('EngineEdition')), 0);
DECLARE @Threshold INT = 0;
DECLARE @Alerts INT = 0;
DECLARE @AlertNames NVARCHAR(MAX) = 'none';
DECLARE @Sessions INT = 0;
DECLARE @SessionNames NVARCHAR(MAX) = 'none';
DECLARE @Sql NVARCHAR(MAX);

BEGIN TRY
    SET @Sql = CASE WHEN @Engine = 5
        THEN N'SELECT @c = COUNT(*), @n = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX), name), '', ''), ''none'') FROM (SELECT DISTINCT s.name FROM sys.database_event_sessions AS s JOIN sys.database_event_session_events AS e ON e.event_session_id = s.event_session_id WHERE e.name LIKE ''%blocked%'' OR e.name LIKE ''%long%'' OR e.name LIKE ''%wait%'') AS x;'
        ELSE N'SELECT @c = COUNT(*), @n = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX), name), '', ''), ''none'') FROM (SELECT DISTINCT s.name FROM sys.server_event_sessions AS s JOIN sys.server_event_session_events AS e ON e.event_session_id = s.event_session_id WHERE e.name LIKE ''%blocked%'' OR e.name LIKE ''%long%'') AS x;' END;
    EXEC sys.sp_executesql @Sql, N'@c INT OUTPUT, @n NVARCHAR(MAX) OUTPUT', @c = @Sessions OUTPUT, @n = @SessionNames OUTPUT;
END TRY
BEGIN CATCH
    SET @Sessions = 0;
END CATCH;

SET @Sessions = ISNULL(@Sessions, 0);
SET @SessionNames = ISNULL(@SessionNames, 'none');

IF @Engine = 5
BEGIN
    SET @Score = CASE WHEN @Sessions > 0 THEN 3 ELSE 2 END;
    SET @Finding = CONCAT('Azure SQL Database: database-scoped Extended Events sessions capturing blocking or long-duration events = ',
        @Sessions, ' [', @SessionNames, ']. SQL Agent alerts and the blocked process threshold do not exist on this platform; ',
        'blocking and long-running query detection is raised by Intelligent Insights through Azure Monitor.');
END
ELSE
BEGIN
    BEGIN TRY
        SELECT @Threshold = ISNULL(MAX(CONVERT(INT, value_in_use)), 0)
        FROM sys.configurations
        WHERE name = 'blocked process threshold (s)';
    END TRY
    BEGIN CATCH
        SET @Threshold = 0;
    END CATCH;

    BEGIN TRY
        SET @Sql = N'SELECT @c = COUNT(*), @n = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX), name), '', ''), ''none'') FROM msdb.dbo.sysalerts WHERE enabled = 1 AND (name LIKE ''%block%'' OR name LIKE ''%long%'' OR name LIKE ''%slow%'' OR name LIKE ''%duration%'' OR performance_condition LIKE ''%Processes blocked%'' OR performance_condition LIKE ''%Longest Transaction%'');';
        EXEC sys.sp_executesql @Sql, N'@c INT OUTPUT, @n NVARCHAR(MAX) OUTPUT', @c = @Alerts OUTPUT, @n = @AlertNames OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Alerts = 0;
    END CATCH;

    SET @Threshold = ISNULL(@Threshold, 0);
    SET @Alerts = ISNULL(@Alerts, 0);
    SET @AlertNames = ISNULL(@AlertNames, 'none');

    SET @Score = CASE
        WHEN @Threshold > 0 AND (@Alerts > 0 OR @Sessions > 0) THEN 3
        WHEN @Alerts > 0 OR @Sessions > 0 THEN 2
        WHEN @Threshold > 0 THEN 1
        ELSE 0
    END;

    SET @Finding = CONCAT('blocked process threshold (s) = ', @Threshold,
        '; enabled SQL Agent alerts targeting blocking or duration = ', @Alerts, ' [', LEFT(@AlertNames, 500), ']',
        '; Extended Events sessions capturing blocking or long-duration events = ', @Sessions, ' [', LEFT(@SessionNames, 500), ']',
        CASE WHEN @Threshold > 0 AND @Alerts = 0 AND @Sessions = 0
             THEN '. The threshold is set but nothing consumes the blocked process report.' ELSE '.' END);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;