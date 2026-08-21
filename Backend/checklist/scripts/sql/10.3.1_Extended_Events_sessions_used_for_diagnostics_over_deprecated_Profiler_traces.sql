-- Checklist: Extended Events sessions used for diagnostics (over deprecated Profiler traces)
-- Scope: SERVER
-- Scoring: 3: Enabled XEvent sessions exist, no active Profiler traces. 2: Enabled XEvent sessions exist, but active Profiler traces also exist. 1: No enabled XEvent sessions, but no active Profiler traces. 0: No enabled XEvent sessions, and active Profiler traces exist.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @XEventCount INT = 0;
DECLARE @TraceCount INT = 0;
DECLARE @XEventNames NVARCHAR(MAX) = '';
DECLARE @TraceNames NVARCHAR(MAX) = '';

-- Check for enabled user-defined Extended Events sessions
SELECT @XEventCount = COUNT(1),
       @XEventNames = STRING_AGG(name, ', ')
FROM sys.server_event_sessions
WHERE is_disabled = 0
  AND name NOT LIKE 'system%';

-- Check for active non-system Profiler traces (sys.traces may not exist on all platforms)
IF OBJECT_ID('sys.traces') IS NOT NULL
BEGIN
    SELECT @TraceCount = COUNT(1),
           @TraceNames = STRING_AGG(CONVERT(NVARCHAR(128), id), ', ')
    FROM sys.traces
    WHERE is_system = 0;
END

SET @DatabaseQueried = 'master';

IF @XEventCount > 0 AND @TraceCount = 0
    SET @Score = 3;
ELSE IF @XEventCount > 0 AND @TraceCount > 0
    SET @Score = 2;
ELSE IF @XEventCount = 0 AND @TraceCount = 0
    SET @Score = 1;
ELSE
    SET @Score = 0;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SET @Finding = CASE 
    WHEN @Score = 3 THEN 'Enabled XEvent sessions: ' + ISNULL(@XEventNames, 'None') + '. No active Profiler traces found.'
    WHEN @Score = 2 THEN 'Enabled XEvent sessions: ' + ISNULL(@XEventNames, 'None') + '. Active Profiler traces found: ' + ISNULL(@TraceNames, 'None') + '.'
    WHEN @Score = 1 THEN 'No enabled XEvent sessions found. No active Profiler traces found.'
    ELSE 'No enabled XEvent sessions found. Active Profiler traces found: ' + ISNULL(@TraceNames, 'None') + '.'
END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;