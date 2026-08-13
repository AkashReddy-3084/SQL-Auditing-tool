-- Checklist: Backups stored redundantly / geo-redundant where required
-- Scope: SERVER
-- Scoring: 0=No backup history found; 1=Backups exist but only in a single location; 2=Backups stored in 2+ distinct locations (proxy for redundancy); 3=Reserved for fully verified compliance (not achievable via proxy evidence)
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

IF OBJECT_ID('msdb.dbo.backupset') IS NOT NULL
BEGIN
    -- On-premises / Azure SQL Managed Instance: evaluate backup history
    SELECT @Score = CASE
        WHEN COUNT(DISTINCT m.physical_device_name) = 0 THEN 0
        WHEN COUNT(DISTINCT m.physical_device_name) = 1 THEN 1
        WHEN COUNT(DISTINCT m.physical_device_name) >= 2 THEN 2
        ELSE 0
    END
    FROM msdb.dbo.backupset b
    JOIN msdb.dbo.backupmediafamily m ON b.media_set_id = m.media_set_id
    WHERE b.database_name NOT IN ('master', 'model', 'msdb', 'tempdb')
      AND b.backup_start_date >= DATEADD(day, -30, GETDATE());
END
ELSE
BEGIN
    -- Azure SQL Database: backups are platform-managed; use service tier as proxy
    IF OBJECT_ID('sys.database_service_objectives') IS NOT NULL
    BEGIN
        SELECT @Score = CASE
            WHEN COUNT(*) = 0 THEN 0
            WHEN MAX(service_objective) LIKE '%GP%' OR MAX(service_objective) LIKE '%BC%' OR MAX(service_objective) LIKE '%P%' THEN 2
            ELSE 1
        END
        FROM sys.database_service_objectives;
    END
    ELSE
    BEGIN
        SET @Score = 0;
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;