-- Checklist: Growth projections modeled for next 6–12 months
-- Scope: SERVER
-- Scoring: 0=No evidence; 1=Minimal (backup history or max_size configured); 2=Good (max_size set + growth trend tracked + monitoring artifact); 3=Explicit planning documentation reviewed (requires human judgment)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @HasBackupHistory BIT = 0;
DECLARE @HasMaxSize BIT = 0;
DECLARE @HasCapacityArtifact BIT = 0;

-- Check 1: Backup history for growth trend (last 6 months)
IF OBJECT_ID('msdb.dbo.backupset') IS NOT NULL
BEGIN
    IF EXISTS (
        SELECT 1 FROM msdb.dbo.backupset
        WHERE type = 'D' 
          AND backup_start_date >= DATEADD(month, -6, GETDATE())
        GROUP BY database_name
        HAVING COUNT(*) >= 2
    )
        SET @HasBackupHistory = 1;
END

-- Check 2: Max size configured (not unlimited) across user databases
IF EXISTS (
    SELECT 1 FROM sys.master_files
    WHERE type = 0 -- data files (0=rows, 1=log)
      AND max_size > 0 -- not unlimited
      AND database_id > 4
)
    SET @HasMaxSize = 1;

-- Check 3: Capacity/Growth tracking artifacts (jobs or custom tables)
IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
BEGIN
    IF EXISTS (
        SELECT 1 FROM msdb.dbo.sysjobs
        WHERE name LIKE '%capacity%' OR name LIKE '%growth%' OR name LIKE '%sizing%' OR name LIKE '%projection%'
    )
        SET @HasCapacityArtifact = 1;
END

-- Fallback: Check for custom capacity tables in master
IF @HasCapacityArtifact = 0
BEGIN
    IF EXISTS (
        SELECT 1 FROM sys.tables
        WHERE name LIKE '%capacity%' OR name LIKE '%growth%' OR name LIKE '%projection%'
    )
        SET @HasCapacityArtifact = 1;
END

-- Calculate Score (fixed conditional order to prevent short-circuiting)
IF @HasBackupHistory = 0 AND @HasMaxSize = 0 AND @HasCapacityArtifact = 0
    SET @Score = 0;
ELSE IF @HasBackupHistory = 1 AND @HasMaxSize = 1 AND @HasCapacityArtifact = 1
    SET @Score = 2;
ELSE
    SET @Score = 1;

-- NOTE: This script provides automated evidence. Full compliance requires human review.
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;