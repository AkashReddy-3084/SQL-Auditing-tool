-- Checklist: Deadlocks captured (Extended Events) and resolved
-- Scope: SERVER
-- Scoring: 0: No Extended Event session configured to capture deadlocks. 1: Session exists but is disabled or misconfigured. 2: Session is active and captures deadlocks, but lacks persistent file target. 3: Session is active, captures deadlocks, and uses an event_file target for persistent logging. NOTE: Deadlock resolution requires human/ETL review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @SessionName NVARCHAR(128);
DECLARE @IsActive BIT;
DECLARE @HasFileTarget BIT;

-- Check for deadlock capture session
SELECT TOP 1
    @SessionName = ses.name,
    @IsActive = CASE WHEN dxs.name IS NOT NULL THEN 1 ELSE 0 END,
    @HasFileTarget = CASE WHEN EXISTS (
        SELECT 1 FROM sys.server_event_session_targets set_
        WHERE set_.event_session_id = ses.event_session_id
          AND set_.target_name = 'event_file'
    ) THEN 1 ELSE 0 END
FROM sys.server_event_sessions ses
JOIN sys.server_event_session_events see ON ses.event_session_id = see.event_session_id
LEFT JOIN sys.dm_xe_sessions dxs ON ses.name = dxs.name
WHERE see.event_name IN ('deadlock_graph', 'xml_deadlock_report');

IF @SessionName IS NOT NULL
BEGIN
    IF @IsActive = 1 AND @HasFileTarget = 1
    BEGIN
        SET @Score = 3;
        SET @Finding = 'Active Extended Event session "' + @SessionName + '" configured to capture deadlocks with event_file target.';
    END
    ELSE IF @IsActive = 1 AND @HasFileTarget = 0
    BEGIN
        SET @Score = 2;
        SET @Finding = 'Active Extended Event session "' + @SessionName + '" configured to capture deadlocks, but lacks persistent file target.';
    END
    ELSE IF @IsActive = 0 AND @HasFileTarget = 1
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Extended Event session "' + @SessionName + '" configured to capture deadlocks with file target, but is currently disabled.';
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Extended Event session "' + @SessionName + '" configured to capture deadlocks, but is disabled and lacks file target.';
    END
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = 'No Extended Event session configured to capture deadlocks.';
END

SET @Finding = @Finding + ' NOTE: This script provides automated evidence. Full compliance requires human review.';

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;