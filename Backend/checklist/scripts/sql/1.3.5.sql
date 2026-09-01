-- Checklist: Connection strings use listener / failover-group endpoints (not a single node)
-- Scope: SERVER
-- Scoring: 3 = AG listener or FCI virtual network name published; 2 = Azure managed endpoint already abstracts the node; 1 = HA replicas present but no abstracted endpoint; 0 = single standalone node

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'No listener or failover-group endpoint evidence could be collected';
DECLARE @Engine INT = ISNULL(CONVERT(INT, SERVERPROPERTY('EngineEdition')), 0);
DECLARE @Clustered INT = ISNULL(CONVERT(INT, SERVERPROPERTY('IsClustered')), 0);
DECLARE @Hadr INT = ISNULL(CONVERT(INT, SERVERPROPERTY('IsHadrEnabled')), 0);
DECLARE @ServerName NVARCHAR(256) = ISNULL(CONVERT(NVARCHAR(256), SERVERPROPERTY('ServerName')), 'unknown');
DECLARE @Listeners INT = 0;
DECLARE @ListenerNames NVARCHAR(MAX) = 'none';
DECLARE @Replicas INT = 0;
DECLARE @Sql NVARCHAR(MAX);

IF @Engine = 5
BEGIN
    SET @Score = 2;
    SET @Finding = CONCAT('Azure SQL Database: clients reach the logical server endpoint for ', @ServerName,
        ', which already abstracts the physical node; a failover-group endpoint replaces that name when one is configured.');
END
ELSE
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT @c = COUNT(*), @n = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX), dns_name), '', ''), ''none'') FROM sys.availability_group_listeners;';
        EXEC sys.sp_executesql @Sql, N'@c INT OUTPUT, @n NVARCHAR(MAX) OUTPUT', @c = @Listeners OUTPUT, @n = @ListenerNames OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Listeners = 0;
    END CATCH;

    BEGIN TRY
        SET @Sql = N'SELECT @r = COUNT(*) FROM sys.availability_replicas;';
        EXEC sys.sp_executesql @Sql, N'@r INT OUTPUT', @r = @Replicas OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Replicas = 0;
    END CATCH;

    SET @Listeners = ISNULL(@Listeners, 0);
    SET @Replicas = ISNULL(@Replicas, 0);
    SET @ListenerNames = ISNULL(@ListenerNames, 'none');

    IF @Listeners > 0
    BEGIN
        SET @Score = 3;
        SET @Finding = CONCAT(@Listeners, ' availability group listener endpoint(s) published: ', @ListenerNames,
            '; availability replicas = ', @Replicas, '. A node-independent endpoint is available instead of ', @ServerName, '.');
    END
    ELSE IF @Clustered = 1
    BEGIN
        SET @Score = 3;
        SET @Finding = CONCAT('Failover cluster instance detected (IsClustered = 1): the published endpoint ', @ServerName,
            ' is the virtual network name, not a physical node. Availability group listeners = 0, replicas = ', @Replicas, '.');
    END
    ELSE IF @Engine = 8
    BEGIN
        SET @Score = 2;
        SET @Finding = CONCAT('Azure SQL Managed Instance: the instance DNS endpoint for ', @ServerName,
            ' abstracts the underlying node. Availability group listeners = 0, replicas = ', @Replicas,
            '; a failover-group endpoint replaces that name when one is configured.');
    END
    ELSE IF @Hadr = 1 OR @Replicas >= 2
    BEGIN
        SET @Score = 1;
        SET @Finding = CONCAT('Always On is enabled (IsHadrEnabled = ', @Hadr, ', availability replicas = ', @Replicas,
            ') but no availability group listener exists, so clients can only name the single node ', @ServerName, '.');
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = CONCAT('Standalone instance ', @ServerName, ': IsHadrEnabled = ', @Hadr, ', IsClustered = ', @Clustered,
            ', availability group listeners = 0, availability replicas = 0. Connection strings can only target this single node.');
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;