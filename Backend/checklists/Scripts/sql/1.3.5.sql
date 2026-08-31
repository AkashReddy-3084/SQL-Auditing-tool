-- Checklist: Connection strings use listener / failover-group endpoints (not a single node)
-- Scope: SERVER
-- Scoring: 3 = AG listener detected; 2 = Azure PaaS logical-server/MI DNS endpoint (node identity already abstracted); 1 = Always On enabled but no listener configured; 0 = no listener/failover-group evidence and no HA infrastructure detected
-- NOTE: Automated evidence only; actual client connection-string usage cannot be verified from the server and requires human review.

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No listener/failover-group evidence found';

IF SERVERPROPERTY('EngineEdition') IN (5, 8)
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure logical server / MI DNS endpoint already abstracts the physical node; verify application connection strings target this endpoint or a configured failover group';
END
ELSE
BEGIN
    DECLARE @IsHadrEnabled INT = ISNULL(CONVERT(INT, SERVERPROPERTY('IsHadrEnabled')), 0);
    DECLARE @ListenerCount INT = 0;

    IF @IsHadrEnabled = 1
        SELECT @ListenerCount = COUNT(*) FROM sys.availability_group_listeners;

    SET @Score = CASE
        WHEN ISNULL(@ListenerCount,0) > 0 THEN 3
        WHEN @IsHadrEnabled = 1 THEN 1
        ELSE 0
    END;
    SET @Finding = CONCAT('IsHadrEnabled = ', @IsHadrEnabled, ', availability group listener count = ', ISNULL(@ListenerCount,0));
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;