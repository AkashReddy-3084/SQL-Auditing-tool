-- Checklist: Reporting workloads isolated from write workloads (read replicas) where possible
-- Scope: SERVER
-- Scoring: 3 = readable secondaries and read-only routing entries exist; 2 = readable secondaries or routing entries exist; 1 = availability metadata is present but no readable secondaries or routing entries exist; 0 = evidence is unavailable
-- NOTE: Automated evidence confirms availability configuration; reporting connection routing and workload behavior require human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'Availability routing evidence unavailable';
DECLARE @RoutingEntryCount INT = 0;
DECLARE @ReadableSecondaryCount INT = 0;
DECLARE @AvailabilityMetadataAvailable BIT = 0;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT @RoutingEntryCount = COUNT(*)
    FROM sys.availability_read_only_routing_lists;
    SET @AvailabilityMetadataAvailable = 1;

    SELECT @ReadableSecondaryCount = COUNT(*)
    FROM sys.availability_replicas
    WHERE secondary_role_allow_connections_desc <> N'NO';
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH;

SET @Score = CASE
    WHEN @ReadError = 1 THEN 0
    WHEN @RoutingEntryCount > 0 AND @ReadableSecondaryCount > 0 THEN 3
    WHEN @RoutingEntryCount > 0 OR @ReadableSecondaryCount > 0 THEN 2
    WHEN @AvailabilityMetadataAvailable = 1 THEN 1
    ELSE 0
END;

SET @Finding = CONCAT(
    N'read-only routing entries = ', @RoutingEntryCount,
    N'; readable secondaries = ', @ReadableSecondaryCount,
    CASE WHEN @ReadError = 1 THEN N'; availability metadata could not be read' ELSE N'' END);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
