-- Checklist: Extended Events sessions used for diagnostics (over deprecated Profiler traces)
-- Scope: SERVER
-- Scoring: 3 = XEvents active & no Profiler; 2 = XEvents active & Profiler present; 1 = No XEvents & no Profiler; 0 = Profiler active & no XEvents

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Unable to determine status';

DECLARE @XEventCount INT = 0;
DECLARE @ProfilerCount INT = 0;

-- Count active Extended Event sessions
SELECT @XEventCount = COUNT(*) 
FROM sys.server_event_sessions 
WHERE state = 1;

-- Check for active Profiler traces (sys.servers is not the source, we use the DMV for active traces)
-- Note: sys.dm_exe_sessions or similar doesn't show traces; we check for the existence of trace files/sessions via system views if available.
-- In modern SQL Server, active traces are visible in sys.traces.
BEGIN TRY
    IF EXISTS (SELECT 1 FROM sys.traces)
    BEGIN
        SELECT @ProfilerCount = COUNT(*) FROM sys.traces;
    END
END TRY
BEGIN CATCH
    SET @ProfilerCount = 0;
END CATCH

IF @XEventCount > 0 AND @ProfilerCount = 0
BEGIN
    SET @Score = 3;
    SET @Finding = 'XEvents active (' + CAST(@XEventCount AS NVARCHAR(10)) + '), no Profiler traces found.';
END
ELSE IF @XEventCount > 0 AND @ProfilerCount > 0
BEGIN
    SET @Score = 2;
    SET @Finding = 'XEvents active (' + CAST(@XEventCount AS NVARCHAR(10)) + '), but Profiler traces also present (' + CAST(@ProfilerCount AS NVARCHAR(10)) + ').';
END
ELSE IF @XEventCount = 0 AND @ProfilerCount = 0
BEGIN
    SET @Score = 1;
    SET @Finding = 'No active XEvent sessions or Profiler traces found.';
END
ELSE -- @XEventCount = 0 AND @ProfilerCount > 0
BEGIN
    SET @Score = 0;
    SET @Finding = 'No XEvents active, but deprecated Profiler traces are running (' + CAST(@ProfilerCount AS NVARCHAR(10)) + ').';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;