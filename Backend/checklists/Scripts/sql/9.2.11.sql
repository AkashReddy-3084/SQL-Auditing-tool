-- Checklist: Backup preference configured and validated across failover
-- Scope: SERVER
-- Scoring: 3 = Availability Groups, a non-NONE backup preference, prioritized replicas, and recent backups are all evidenced; 2 = Availability Groups and at least two supporting signals are present; 1 = one supporting signal is present; 0 = evidence is unavailable or no supporting configuration is found
-- NOTE: Automated evidence cannot prove that a failover drill was performed or that backup routing was observed during failover.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'Availability and backup preference evidence unavailable';
DECLARE @AvailabilityGroupCount INT = 0;
DECLARE @BackupPreference INT = -1;
DECLARE @PrioritizedReplicaCount INT = 0;
DECLARE @RecentBackupCount INT = 0;
DECLARE @EvidenceCount INT = 0;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT @AvailabilityGroupCount = COUNT(*)
    FROM sys.availability_groups;

    SELECT @BackupPreference = ISNULL(MAX(CONVERT(INT, automated_backup_preference)), -1)
    FROM sys.availability_groups;

    SELECT @PrioritizedReplicaCount = COUNT(*)
    FROM sys.availability_replicas
    WHERE backup_priority > 0;

    SELECT @RecentBackupCount = COUNT(*)
    FROM msdb.dbo.backupset
    WHERE backup_finish_date > DATEADD(DAY, -30, GETDATE());
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

SET @EvidenceCount =
    CASE WHEN @BackupPreference > 0 THEN 1 ELSE 0 END
  + CASE WHEN @PrioritizedReplicaCount > 0 THEN 1 ELSE 0 END
  + CASE WHEN @RecentBackupCount > 0 THEN 1 ELSE 0 END;

SET @Score = CASE
    WHEN @ReadError = 1 THEN 0
    WHEN @AvailabilityGroupCount > 0 AND @BackupPreference > 0
         AND @PrioritizedReplicaCount > 0 AND @RecentBackupCount > 0 THEN 3
    WHEN @AvailabilityGroupCount > 0 AND @EvidenceCount >= 2 THEN 2
    WHEN @EvidenceCount > 0 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'Availability Groups = ', @AvailabilityGroupCount,
    N'; automated backup preference = ', @BackupPreference,
    N'; replicas with backup priority > 0 = ', @PrioritizedReplicaCount,
    N'; backups in the last 30 days = ', @RecentBackupCount,
    CASE WHEN @ReadError = 1 THEN N'; one or more availability or backup sources could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
