-- Checklist: Backup strategy defined and matches RPO (full/differential/log or PaaS automated)
-- Scope: SERVER
-- Scoring: 0=No recent backups; 1=Only full backups; 2=Full+Diff or irregular logs; 3=Full+Diff+Log with <=60min intervals or PaaS automated backups
-- NOTE: This script provides automated evidence. Full compliance requires human review.
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';

IF OBJECT_ID('msdb.dbo.backupset') IS NOT NULL
BEGIN
    -- On-prem / SQL MI evaluation (proxy evidence based on backup frequency)
    WITH BackupStats AS (
        SELECT
            database_name,
            type,
            COUNT(*) AS backup_count,
            MIN(backup_start_date) AS first_backup,
            MAX(backup_start_date) AS last_backup
        FROM msdb.dbo.backupset
        WHERE database_name NOT IN ('master', 'model', 'msdb', 'tempdb')
          AND type IN ('D', 'I', 'L')
          AND backup_start_date >= DATEADD(day, -7, GETDATE())
        GROUP BY database_name, type
    ),
    Aggregated AS (
        SELECT
            ISNULL(SUM(CASE WHEN type = 'D' THEN backup_count ELSE 0 END), 0) AS full_count,
            ISNULL(SUM(CASE WHEN type = 'I' THEN backup_count ELSE 0 END), 0) AS diff_count,
            ISNULL(SUM(CASE WHEN type = 'L' THEN backup_count ELSE 0 END), 0) AS log_count,
            CASE 
                WHEN ISNULL(SUM(CASE WHEN type = 'L' THEN backup_count ELSE 0 END), 0) > 1
                THEN DATEDIFF(minute, MIN(CASE WHEN type = 'L' THEN first_backup END), MAX(CASE WHEN type = 'L' THEN last_backup END)) * 1.0 
                     / (ISNULL(SUM(CASE WHEN type = 'L' THEN backup_count ELSE 0 END), 0) - 1)
                ELSE 9999
            END AS avg_log_gap_minutes
        FROM BackupStats
    )
    SELECT @Score = CASE
        WHEN full_count = 0 THEN 0
        WHEN diff_count = 0 AND log_count = 0 THEN 1
        WHEN log_count = 0 THEN 2
        WHEN log_count > 0 AND avg_log_gap_minutes <= 60 THEN 3
        ELSE 2
    END
    FROM Aggregated;
END
ELSE
BEGIN
    -- Azure SQL DB fallback (direct configuration check)
    IF OBJECT_ID('sys.database_service_objectives') IS NOT NULL
    BEGIN
        SELECT @Score = CASE
            WHEN COUNT(*) = 0 THEN 0
            WHEN ISNULL(MAX(backup_retention_days), 0) = 0 THEN 1
            WHEN ISNULL(MAX(backup_retention_days), 0) >= 7 THEN 2
            WHEN ISNULL(MAX(backup_retention_days), 0) >= 35 THEN 3
        END
        FROM sys.database_service_objectives;
    END
    ELSE
    BEGIN
        SET @Score = 1; -- Indirect evidence only
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score;