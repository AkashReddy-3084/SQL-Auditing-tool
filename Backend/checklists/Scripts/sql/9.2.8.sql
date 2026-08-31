-- Checklist: Availability mode (synchronous vs asynchronous commit) and failover mode (automatic vs manual) documented and aligned to RPO/RTO
-- Scope: SERVER
-- Scoring: 3 = a replica combines SYNCHRONOUS_COMMIT + AUTOMATIC failover (or Azure SQL DB platform-managed failover); 2 = reserved; 1 = an AG exists but no such combination found; 0 = no AG configured and not Azure SQL Database
-- NOTE: Automated evidence only; whether the configured mode was deliberately aligned to a documented RPO/RTO target is not independently verified. Full compliance requires human review.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX);

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Score = 3;
    SET @Finding = 'Azure SQL Database: failover mode/availability behavior is platform-managed';
END
ELSE
BEGIN
    DECLARE @AgCount INT = 0, @SyncAutoReplicaCount INT = 0;

    IF OBJECT_ID('sys.availability_replicas') IS NOT NULL
    BEGIN
        SELECT @AgCount = COUNT(*) FROM sys.availability_groups;

        SELECT @SyncAutoReplicaCount = COUNT(*)
        FROM sys.availability_replicas ar
        WHERE ar.availability_mode_desc = 'SYNCHRONOUS_COMMIT' AND ar.failover_mode_desc = 'AUTOMATIC';
    END

    SET @Score = CASE WHEN ISNULL(@AgCount,0) = 0 THEN 0
                      WHEN ISNULL(@SyncAutoReplicaCount,0) > 0 THEN 3
                      ELSE 1 END;
    SET @Finding = CASE WHEN ISNULL(@AgCount,0) = 0 THEN 'No Availability Group configured'
                        ELSE CONCAT('Availability Groups = ', @AgCount, ', replicas with SYNCHRONOUS_COMMIT + AUTOMATIC failover = ', ISNULL(@SyncAutoReplicaCount,0)) END;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;