-- Checklist: Alias / DNS resolution and failover behavior documented and validated — applications reconnect transparently on failover with no manual repoint
-- Scope: SERVER
-- Scoring: 0=No HA topology, 1=AG configured but no listener, 2=Listener configured (proxy evidence), 3=Not achievable (requires human review of documentation/validation)

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @ListenerCount INT;
DECLARE @AgCount INT;
DECLARE @EngineEdition INT;

SET @EngineEdition = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
SET @DatabaseQueried = 'master';

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: HA is platform-managed
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database: High availability is managed by the platform. NOTE: This script provides automated evidence. Full compliance requires human review.';
END
ELSE
BEGIN
    SELECT @AgCount = COUNT(*) FROM sys.availability_groups;
    SELECT @ListenerCount = COUNT(*) FROM sys.availability_group_listeners;

    IF @ListenerCount > 0
    BEGIN
        SET @Score = 2;
        SELECT @Finding = STRING_AGG(name, ', ') + ' configured. NOTE: This script provides automated evidence. Full compliance requires human review.'
        FROM sys.availability_group_listeners;
    END
    ELSE IF @AgCount > 0
    BEGIN
        SET @Score = 1;
        SET @Finding = 'Availability group(s) configured but no listener found.';
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'No high availability topology configured.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;