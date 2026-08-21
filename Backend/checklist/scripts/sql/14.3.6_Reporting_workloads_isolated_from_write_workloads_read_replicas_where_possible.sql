-- Checklist: Reporting workloads isolated from write workloads (read replicas) where possible
-- Scope: SERVER
-- Scoring: 0: No read replicas or AGs configured. 1: AGs exist but secondaries are not readable. 2: Readable secondaries exist but read-only routing is not configured. 3: Readable secondaries exist with read-only routing configured.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

SET @DatabaseQueried = 'master';

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database
    IF OBJECT_ID('sys.dm_database_copies') IS NOT NULL
    BEGIN
        DECLARE @ReadOnlyCopies INT = 0;
        SELECT @ReadOnlyCopies = COUNT(*) FROM sys.dm_database_copies WHERE is_read_only = 1;
        
        IF @ReadOnlyCopies > 0
        BEGIN
            SET @Score = 3;
            SET @Finding = 'Azure SQL Database read replica(s) detected: ' + CAST(@ReadOnlyCopies AS NVARCHAR(10)) + ' read-only copy(s) configured.';
        END
        ELSE
        BEGIN
            SET @Score = 0;
            SET @Finding = 'No read replicas configured for Azure SQL Database.';
        END
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'Read replica metadata view unavailable; unable to verify read replica configuration.';
    END
END
ELSE
BEGIN
    -- SQL Server / Azure SQL Managed Instance
    IF OBJECT_ID('sys.availability_replicas') IS NOT NULL
    BEGIN
        DECLARE @ReadableReplicas INT = 0;
        DECLARE @RoutingConfigured INT = 0;
        DECLARE @TotalReplicas INT = 0;
        
        SELECT 
            @TotalReplicas = COUNT(*),
            @ReadableReplicas = COUNT(CASE WHEN secondary_role_allow_connections_desc = 'READ_ONLY' THEN 1 END),
            @RoutingConfigured = COUNT(CASE WHEN secondary_role_allow_connections_desc = 'READ_ONLY' AND read_only_routing_url IS NOT NULL THEN 1 END)
        FROM sys.availability_replicas;

        IF @TotalReplicas = 0
        BEGIN
            SET @Score = 0;
            SET @Finding = 'No Always On Availability Groups or read replicas configured.';
        END
        ELSE IF @ReadableReplicas = 0
        BEGIN
            SET @Score = 1;
            SET @Finding = 'Always On Availability Groups configured (' + CAST(@TotalReplicas AS NVARCHAR(10)) + ' replica(s)), but secondaries are not readable.';
        END
        ELSE IF @RoutingConfigured = 0
        BEGIN
            SET @Score = 2;
            SET @Finding = 'Readable secondary replicas configured (' + CAST(@ReadableReplicas AS NVARCHAR(10)) + '), but read-only routing is not configured.';
        END
        ELSE
        BEGIN
            SET @Score = 3;
            SET @Finding = 'Readable secondary replicas configured (' + CAST(@ReadableReplicas AS NVARCHAR(10)) + ') with read-only routing enabled.';
        END
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = 'Always On Availability Groups not supported or not installed on this instance.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;