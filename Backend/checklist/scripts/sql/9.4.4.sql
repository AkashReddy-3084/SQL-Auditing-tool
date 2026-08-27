-- Checklist: Historical SLA compliance tracked and reported
-- Scope: SERVER
-- Scoring: 2 = historical Agent runs and SLA/run-log tables exist; 1 = partial history evidence; 0 = no history evidence
-- NOTE: Automated evidence only; SLA definitions and compliance reporting require human review.

SET NOCOUNT ON;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'SLA history metadata could not be evaluated';
DECLARE @HistoryRows INT = 0;
DECLARE @RecentHistory INT = 0;
DECLARE @SlaTables INT = 0;

BEGIN TRY
    SELECT @HistoryRows = COUNT(*) FROM msdb.dbo.sysjobhistory;
    SELECT @RecentHistory = COUNT(*) FROM msdb.dbo.sysjobhistory WHERE run_date > CONVERT(INT, CONVERT(VARCHAR(8), DATEADD(day, -90, GETDATE()), 112));
    SELECT @SlaTables = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0 AND (name LIKE '%sla%' OR name LIKE '%runlog%' OR name LIKE '%duration%');
    SET @Score = CASE WHEN @HistoryRows > 0 AND @RecentHistory > 0 AND @SlaTables > 0 THEN 2 WHEN @HistoryRows > 0 OR @SlaTables > 0 THEN 1 ELSE 0 END;
    SET @Finding = N'history_rows=' + CONVERT(NVARCHAR(20), @HistoryRows) + N', recent_history=' + CONVERT(NVARCHAR(20), @RecentHistory) + N', sla_tables=' + CONVERT(NVARCHAR(20), @SlaTables);
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @Finding = N'Unable to read SLA history metadata: ' + ERROR_MESSAGE();
END CATCH;
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;