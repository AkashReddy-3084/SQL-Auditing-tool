-- Checklist: Blocking monitored and root causes addressed
-- Scope: SERVER
-- Scoring: 3 = required blocking monitors configured and no session currently blocked; 2 = at least one monitor configured; 1 = no monitor configured but nothing currently blocked; 0 = no monitor configured and sessions are blocked, or metadata unreadable

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Blocking monitoring metadata could not be read';
DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Threshold INT = 0;
DECLARE @XeSessions INT = 0;
DECLARE @Alerts INT = 0;
DECLARE @Blocked INT = 0;
DECLARE @MaxWaitSec INT = 0;
DECLARE @Signals INT = 0;
DECLARE @Needed INT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 2 END;
DECLARE @Readable BIT = 0;
DECLARE @Sql NVARCHAR(MAX);

BEGIN TRY
    SELECT @Threshold = ISNULL(MAX(CONVERT(INT, c.value_in_use)), 0)
    FROM sys.configurations AS c
    WHERE c.name = 'blocked process threshold (s)';
    SET @Readable = 1;
END TRY
BEGIN CATCH
    SET @Threshold = 0;
END CATCH;

BEGIN TRY
    IF @Edition = 5
        SET @Sql = N'SELECT @n = COUNT(*)
                     FROM sys.database_event_sessions AS s
                     JOIN sys.database_event_session_events AS e ON e.event_session_id = s.event_session_id
                     WHERE e.name LIKE ''%blocked_process%'' OR e.name LIKE ''%lock_%'';';
    ELSE
        SET @Sql = N'SELECT @n = COUNT(*)
                     FROM sys.server_event_sessions AS s
                     JOIN sys.server_event_session_events AS e ON e.event_session_id = s.event_session_id
                     WHERE e.name LIKE ''%blocked_process%'' OR e.name LIKE ''%lock_%'';';

    EXEC sys.sp_executesql @Sql, N'@n INT OUTPUT', @n = @XeSessions OUTPUT;
    SET @Readable = 1;
END TRY
BEGIN CATCH
    SET @XeSessions = 0;
END CATCH;

IF @Edition <> 5
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT @n = COUNT(*)
                     FROM msdb.dbo.sysalerts AS a
                     WHERE a.name LIKE ''%block%'' OR a.name LIKE ''%deadlock%''
                        OR a.performance_condition LIKE ''%Lock Wait%'';';
        EXEC sys.sp_executesql @Sql, N'@n INT OUTPUT', @n = @Alerts OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Alerts = 0;
    END CATCH;
END

BEGIN TRY
    SELECT @Blocked = COUNT(*),
           @MaxWaitSec = ISNULL(MAX(r.wait_time), 0) / 1000
    FROM sys.dm_exec_requests AS r
    WHERE r.blocking_session_id <> 0
      AND r.session_id <> @@SPID;
    SET @Readable = 1;
END TRY
BEGIN CATCH
    SET @Blocked = 0;
END CATCH;

SET @Signals = CASE WHEN @Threshold > 0 THEN 1 ELSE 0 END
             + CASE WHEN @XeSessions > 0 THEN 1 ELSE 0 END
             + CASE WHEN @Alerts > 0 THEN 1 ELSE 0 END;

SET @Score = CASE
                WHEN @Readable = 0 THEN 0
                WHEN @Signals >= @Needed AND @Blocked = 0 THEN 3
                WHEN @Signals >= 1 THEN 2
                WHEN @Blocked = 0 THEN 1
                ELSE 0
             END;

IF @Readable = 1
    SET @Finding = CONCAT('blocked process threshold (s) = ', @Threshold, ', extended event sessions capturing blocking = ',
                          @XeSessions, ', SQL Agent blocking/deadlock alerts = ', @Alerts,
                          ', sessions currently blocked = ', @Blocked,
                          CASE WHEN @Blocked > 0 THEN CONCAT(' with a longest wait of ', @MaxWaitSec, ' second(s)') ELSE '' END);

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;

