-- Checklist: Secondary region/replica capacity provisioned or evaluated
-- Scope: SERVER
-- Scoring: 3 = Availability Groups, multiple replicas, a secondary role, and CPU capacity are all evidenced; 2 = Availability Groups and at least two supporting signals are present; 1 = one availability/capacity signal is present; 0 = evidence is unavailable or no secondary-capacity signal is found
-- NOTE: Automated evidence confirms topology and CPU capacity; whether capacity was sized for failover workload requires human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'Availability and capacity evidence unavailable';
DECLARE @ReplicaCount INT = 0;
DECLARE @AvailabilityGroupCount INT = 0;
DECLARE @SecondaryCount INT = 0;
DECLARE @CpuCount INT = 0;
DECLARE @EvidenceCount INT = 0;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT @ReplicaCount = COUNT(*)
    FROM sys.availability_replicas;

    SELECT @AvailabilityGroupCount = COUNT(*)
    FROM sys.availability_groups;

    SELECT @SecondaryCount = COUNT(*)
    FROM sys.dm_hadr_availability_replica_states
    WHERE role_desc = N'SECONDARY';

    SELECT @CpuCount = ISNULL(MAX(cpu_count), 0)
    FROM sys.dm_os_sys_info;
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

SET @EvidenceCount =
    CASE WHEN @ReplicaCount > 0 THEN 1 ELSE 0 END
  + CASE WHEN @SecondaryCount > 0 THEN 1 ELSE 0 END
  + CASE WHEN @CpuCount > 0 THEN 1 ELSE 0 END;

SET @Score = CASE
    WHEN @ReadError = 1 THEN 0
    WHEN @AvailabilityGroupCount > 0 AND @ReplicaCount > 1
         AND @SecondaryCount > 0 AND @CpuCount > 0 THEN 3
    WHEN @AvailabilityGroupCount > 0 AND @EvidenceCount >= 2 THEN 2
    WHEN @EvidenceCount > 0 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'Availability Groups = ', @AvailabilityGroupCount,
    N'; replicas = ', @ReplicaCount,
    N'; secondary-role replicas = ', @SecondaryCount,
    N'; CPUs = ', @CpuCount,
    CASE WHEN @ReadError = 1 THEN N'; one or more availability sources could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
