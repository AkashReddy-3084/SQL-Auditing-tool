-- Checklist: ETL windows avoid contention with reporting/query workloads
-- Scope: SERVER
-- Scoring: 3 = all enabled schedules run off peak; 2 = most enabled schedules run off peak; 1 = some schedules run off peak; 0 = no enabled schedules
-- NOTE: Automated evidence only; workload contention requires query-performance review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'SQL Agent schedule metadata could not be evaluated';
DECLARE @Scheduled INT = 0;
DECLARE @OffPeak INT = 0;

BEGIN TRY
    SELECT @Scheduled = COUNT(*),
           @OffPeak = ISNULL(SUM(CASE WHEN s.active_start_time < 70000 OR s.active_start_time >= 190000 THEN 1 ELSE 0 END), 0)
    FROM msdb.dbo.sysjobschedules AS js
    JOIN msdb.dbo.sysschedules AS s ON js.schedule_id = s.schedule_id
    WHERE s.enabled = 1;

    SET @Score = CASE WHEN @Scheduled = 0 THEN 0
                      WHEN @OffPeak = @Scheduled THEN 3
                      WHEN CONVERT(DECIMAL(9, 4), @OffPeak) / NULLIF(@Scheduled, 0) >= 0.75 THEN 2
                      WHEN @OffPeak > 0 THEN 1 ELSE 0 END;
    SET @Finding = N'scheduled=' + CONVERT(NVARCHAR(20), @Scheduled) + N', off_peak=' + CONVERT(NVARCHAR(20), @OffPeak);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read SQL Agent schedule metadata: ' + ERROR_MESSAGE();
END CATCH;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;