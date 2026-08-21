-- Checklist: HA approach defined and matches SLA (Always On AG / failover cluster / zone-redundant / failover groups)
-- Scope: SERVER
-- Scoring: 0: No HA topology detected. 1: Legacy/Partial HA detected. 2: Standard HA detected (AG/FCI/FG). 3: Robust HA with zone-redundancy/multi-region. NOTE: SLA alignment requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @HasAG INT = 0;
DECLARE @HasFCI INT = 0;
DECLARE @HasFG INT = 0;
DECLARE @HasLegacy INT = 0;
DECLARE @Sql NVARCHAR(MAX);

-- Detect Always On AG
IF OBJECT_ID('sys.availability_groups') IS NOT NULL
BEGIN
    SET @Sql = N'SELECT @HasAG = COUNT(*) FROM sys.availability_groups;';
    EXEC sp_executesql @Sql, N'@HasAG INT OUTPUT', @HasAG OUTPUT;
END

-- Detect Failover Cluster
IF @EngineEdition <> 5
BEGIN
    SET @Sql = N'SELECT @HasFCI = COUNT(*) FROM sys.dm_os_cluster_nodes;';
    EXEC sp_executesql @Sql, N'@HasFCI INT OUTPUT', @HasFCI OUTPUT;
END

-- Detect Failover Groups (Azure SQL DB)
IF @EngineEdition = 5 AND OBJECT_ID('sys.failover_groups') IS NOT NULL
BEGIN
    SET @Sql = N'SELECT @HasFG = COUNT(*) FROM sys.failover_groups;';
    EXEC sp_executesql @Sql, N'@HasFG INT OUTPUT', @HasFG OUTPUT;
END

-- Detect Legacy HA (Log Shipping)
IF @EngineEdition <> 5 AND OBJECT_ID('msdb.dbo.log_shipping_primary_databases') IS NOT NULL
BEGIN
    SET @Sql = N'SELECT @HasLegacy = COUNT(*) FROM msdb.dbo.log_shipping_primary_databases;';
    EXEC sp_executesql @Sql, N'@HasLegacy INT OUTPUT', @HasLegacy OUTPUT;
END

-- Determine Score and Finding
IF @HasAG > 0 OR @HasFCI > 0 OR @HasFG > 0
BEGIN
    SET @Score = 2;
    SET @Finding = 'Standard HA topology detected: ';
    IF @HasAG > 0 SET @Finding = @Finding + 'Always On AG (' + CAST(@HasAG AS NVARCHAR(10)) + '), ';
    IF @HasFCI > 0 SET @Finding = @Finding + 'Failover Cluster (' + CAST(@HasFCI AS NVARCHAR(10)) + ' nodes), ';
    IF @HasFG > 0 SET @Finding = @Finding + 'Failover Group (' + CAST(@HasFG AS NVARCHAR(10)) + '), ';
    SET @Finding = LEFT(@Finding, LEN(@Finding) - 2);
    
    IF @HasFG > 0 OR (@HasAG > 0 AND SERVERPROPERTY('IsHadrEnabled') = 1)
    BEGIN
        SET @Score = 3;
        SET @Finding = @Finding + ' with high-availability configuration.';
    END
END
ELSE IF @HasLegacy > 0
BEGIN
    SET @Score = 1;
    SET @Finding = 'Legacy/Partial HA detected: Log Shipping (' + CAST(@HasLegacy AS NVARCHAR(10)) + ' databases).';
END
ELSE
BEGIN
    SET @Score = 0;
    SET @Finding = 'No High Availability topology detected.';
END

SET @Finding = @Finding + ' NOTE: This script provides automated evidence. Full compliance requires human review.';
SET @DatabaseQueried = 'master';
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;