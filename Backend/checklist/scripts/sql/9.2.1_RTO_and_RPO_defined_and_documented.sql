-- Checklist: RTO and RPO defined and documented
-- Scope: SERVER
-- Scoring: 0 = No recent backups or HA/DR features; 1 = Full backups only, no log backups/AG/LS; 2 = Log backups or AG/LS configured (proxy evidence for RTO/RPO support); 3 = Fully configured synchronous AG + frequent log backups + explicit documentation verification (requires human review)
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @HasRecentFull BIT = 0;
DECLARE @HasLogBackups BIT = 0;
DECLARE @HasAG BIT = 0;
DECLARE @HasSyncAG BIT = 0;
DECLARE @HasLS BIT = 0;

-- Check recent full backups (last 7 days)
IF OBJECT_ID('msdb.dbo.backupset') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM msdb.dbo.backupset WHERE type = 'D' AND backup_finish_date > DATEADD(day, -7, GETDATE()))
        SET @HasRecentFull = 1;

    -- Proxy for "frequent log backups": at least one log backup in the last 24 hours
    IF EXISTS (SELECT 1 FROM msdb.dbo.backupset WHERE type = 'L' AND backup_finish_date > DATEADD(day, -1, GETDATE()))
        SET @HasLogBackups = 1;
END

-- Check Availability Groups
IF OBJECT_ID('sys.availability_groups') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.availability_groups) SET @HasAG = 1;
    
    -- Check for synchronous commit configuration (proxy for synchronous AG)
    IF OBJECT_ID('sys.availability_replicas') IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.availability_replicas WHERE synchronous_commit_partner_id IS NOT NULL)
            SET @HasSyncAG = 1;
    END
END

-- Check Log Shipping
IF OBJECT_ID('msdb.dbo.log_shipping_primary_databases') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM msdb.dbo.log_shipping_primary_databases) SET @HasLS = 1;
END

-- Evaluate score based on infrastructure readiness for RTO/RPO
IF @HasRecentFull = 0 OR (@HasLogBackups = 0 AND @HasAG = 0 AND @HasLS = 0)
    SET @Score = 0;
ELSE IF @HasLogBackups = 0 AND @HasAG = 0 AND @HasLS = 0
    SET @Score = 1;
ELSE IF @HasLogBackups = 1 OR @HasAG = 1 OR @HasLS = 1
    SET @Score = 2;
ELSE IF @HasSyncAG = 1 AND @HasLogBackups = 1
    SET @Score = 3;

-- Cap at 2: Full compliance (Score 3) requires explicit documentation verification, which must be performed manually.
SET @Score = CASE WHEN @Score > 2 THEN 2 ELSE @Score END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score;