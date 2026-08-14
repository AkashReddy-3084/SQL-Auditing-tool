-- Checklist: Backups restore-tested regularly (not just taken)
-- Scope: SERVER
-- Scoring: 0=No restore history in 90 days; 1=History older than 30 days or sparse; 2=Recent restores (30 days) for majority of DBs or dedicated restore jobs found; 3=Not achievable automatically (proxy evidence capped at 2)
SET NOCOUNT ON;
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @UserDbCount INT = 0;
DECLARE @RecentRestoreCount INT = 0;
DECLARE @JobCount INT = 0;

-- Check if msdb is available (On-prem / MI)
IF OBJECT_ID('msdb.dbo.restorehistory') IS NOT NULL
BEGIN
    SELECT @UserDbCount = COUNT(*) FROM sys.databases WHERE database_id > 4 AND state = 0;
    
    SELECT @RecentRestoreCount = COUNT(DISTINCT rh.destination_database_name)
    FROM msdb.dbo.restorehistory rh
    WHERE rh.restore_date >= DATEADD(DAY, -30, GETDATE())
      AND rh.destination_database_name NOT IN ('master', 'model', 'msdb', 'tempdb');

    IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
    BEGIN
        SELECT @JobCount = COUNT(*)
        FROM msdb.dbo.sysjobs j
        WHERE j.enabled = 1
          AND (j.name LIKE '%restore%' OR j.name LIKE '%test%' OR j.name LIKE '%verify%');
    END;

    IF (@UserDbCount > 0 AND @RecentRestoreCount * 2 >= @UserDbCount) OR @JobCount > 0
        SET @Score = 2;
    ELSE IF @RecentRestoreCount > 0
        SET @Score = 1;
    ELSE
    BEGIN
        -- Check for older restores (30-90 days)
        DECLARE @OldRestoreCount INT = 0;
        SELECT @OldRestoreCount = COUNT(DISTINCT rh.destination_database_name)
        FROM msdb.dbo.restorehistory rh
        WHERE rh.restore_date >= DATEADD(DAY, -90, GETDATE())
          AND rh.restore_date < DATEADD(DAY, -30, GETDATE())
          AND rh.destination_database_name NOT IN ('master', 'model', 'msdb', 'tempdb');
        
        IF @OldRestoreCount > 0 SET @Score = 1;
    END;
END
ELSE
BEGIN
    -- Azure SQL DB (managed backups/restores)
    SET @Score = 1;
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;
-- NOTE: This script provides automated evidence. Full compliance requires human review.