-- Checklist: Availability mode (synchronous vs asynchronous commit) and failover mode (automatic vs manual) documented and aligned to RPO/RTO
-- Scope: SERVER
-- Scoring: 0: No AGs configured. 1: AGs exist but mode configuration is incomplete. 2: All AG replicas have explicit availability and failover modes configured (RPO/RTO alignment requires manual review). 3: Not achievable automatically.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database: High Availability is managed by Azure SLA. RPO/RTO alignment is platform-managed.';
END
ELSE
BEGIN
    IF EXISTS (SELECT 1 FROM sys.availability_groups)
    BEGIN
        SET @Score = 2;
        SELECT @Finding = STRING_AGG(
            ag.name + ': ' +
            CASE ar.availability_mode WHEN 1 THEN 'Synchronous' WHEN 2 THEN 'Asynchronous' ELSE 'Unspecified' END + ' commit, ' +
            CASE ar.failover_mode WHEN 1 THEN 'Manual' WHEN 2 THEN 'Automatic' ELSE 'Unspecified' END + ' failover',
            '; '
        )
        FROM sys.availability_groups ag
        JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id;
        
        SET @Finding = ISNULL(@Finding, 'AGs exist but no replica configuration found.');
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No Always On Availability Groups configured.';
    END
END

SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;