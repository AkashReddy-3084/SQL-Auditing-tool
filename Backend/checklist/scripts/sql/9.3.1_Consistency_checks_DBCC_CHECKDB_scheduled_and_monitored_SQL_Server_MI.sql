SET NOCOUNT ON;
-- Check if any SQL Agent job contains DBCC CHECKDB command (proxy for scheduled consistency checks)
IF EXISTS(
    SELECT 1 FROM msdb.dbo.sysjobsteps s WHERE s.command LIKE '%DBCC CHECKDB%'
)
    SELECT 'Passed' AS Result;
ELSE
    SELECT 'NeedsReview' AS Result;
