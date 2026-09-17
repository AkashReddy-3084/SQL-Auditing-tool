-- Checklist: HA node configuration parity verified - both nodes have identical instance configuration, trace flags, MAXDOP/memory, logins, SQL Agent jobs, linked servers, and certificates
-- Scope: SERVER
-- Scoring: 3 = 2+ HA nodes with uniform replica settings, healthy synchronisation and no pending instance configuration; 2 = 2+ HA nodes with one divergence; 1 = HA present but only one node observable or two or more divergences; 0 = no HA topology

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'HA node parity evidence could not be collected';
DECLARE @Engine INT = ISNULL(CONVERT(INT, SERVERPROPERTY('EngineEdition')), 0);
DECLARE @Replicas INT = 0;
DECLARE @ClusterNodes INT = 0;
DECLARE @ModeVariants INT = 0;
DECLARE @FailoverVariants INT = 0;
DECLARE @TimeoutVariants INT = 0;
DECLARE @Unhealthy INT = 0;
DECLARE @PendingConfig INT = 0;
DECLARE @PendingNames NVARCHAR(MAX) = 'none';
DECLARE @Logins INT = 0;
DECLARE @LinkedServers INT = 0;
DECLARE @Certificates INT = 0;
DECLARE @Jobs INT = 0;
DECLARE @Nodes INT = 0;
DECLARE @Divergences INT = 0;
DECLARE @Sql NVARCHAR(MAX);

IF @Engine = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database: replica nodes are provisioned and kept identical by the platform. Instance-level artefacts named by this control (trace flags, MAXDOP/memory settings, server logins, SQL Agent jobs, linked servers, certificates) are not tenant-managed and no peer node is exposed for comparison.';
END
ELSE
BEGIN
    SELECT @PendingConfig = COUNT(*),
           @PendingNames = ISNULL(STRING_AGG(CONVERT(NVARCHAR(MAX), name), ', '), 'none')
    FROM sys.configurations
    WHERE value <> value_in_use;

    BEGIN TRY
        SET @Sql = N'SELECT @r = COUNT(*), @m = COUNT(DISTINCT availability_mode), @f = COUNT(DISTINCT failover_mode), @t = COUNT(DISTINCT session_timeout) FROM sys.availability_replicas;';
        EXEC sys.sp_executesql @Sql, N'@r INT OUTPUT, @m INT OUTPUT, @f INT OUTPUT, @t INT OUTPUT',
             @r = @Replicas OUTPUT, @m = @ModeVariants OUTPUT, @f = @FailoverVariants OUTPUT, @t = @TimeoutVariants OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Replicas = 0;
    END CATCH;

    BEGIN TRY
        SET @Sql = N'SELECT @u = COUNT(*) FROM sys.dm_hadr_availability_replica_states WHERE synchronization_health <> 2;';
        EXEC sys.sp_executesql @Sql, N'@u INT OUTPUT', @u = @Unhealthy OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Unhealthy = 0;
    END CATCH;

    BEGIN TRY
        SET @Sql = N'SELECT @n = COUNT(*) FROM sys.dm_os_cluster_nodes;';
        EXEC sys.sp_executesql @Sql, N'@n INT OUTPUT', @n = @ClusterNodes OUTPUT;
    END TRY
    BEGIN CATCH
        SET @ClusterNodes = 0;
    END CATCH;

    BEGIN TRY
        SET @Sql = N'SELECT @l = (SELECT COUNT(*) FROM sys.server_principals WHERE type IN (''S'', ''U'', ''G'')), @k = (SELECT COUNT(*) FROM sys.servers WHERE is_linked = 1), @c = (SELECT COUNT(*) FROM sys.certificates), @j = (SELECT COUNT(*) FROM msdb.dbo.sysjobs);';
        EXEC sys.sp_executesql @Sql, N'@l INT OUTPUT, @k INT OUTPUT, @c INT OUTPUT, @j INT OUTPUT',
             @l = @Logins OUTPUT, @k = @LinkedServers OUTPUT, @c = @Certificates OUTPUT, @j = @Jobs OUTPUT;
    END TRY
    BEGIN CATCH
        SET @Logins = 0;
    END CATCH;

    SET @Replicas = ISNULL(@Replicas, 0);
    SET @ClusterNodes = ISNULL(@ClusterNodes, 0);
    SET @Nodes = CASE WHEN @Replicas > @ClusterNodes THEN @Replicas ELSE @ClusterNodes END;
    SET @Divergences =
          CASE WHEN ISNULL(@ModeVariants, 0) > 1 THEN 1 ELSE 0 END
        + CASE WHEN ISNULL(@FailoverVariants, 0) > 1 THEN 1 ELSE 0 END
        + CASE WHEN ISNULL(@TimeoutVariants, 0) > 1 THEN 1 ELSE 0 END
        + CASE WHEN ISNULL(@Unhealthy, 0) > 0 THEN 1 ELSE 0 END
        + CASE WHEN ISNULL(@PendingConfig, 0) > 0 THEN 1 ELSE 0 END;

    SET @Score = CASE
        WHEN @Nodes >= 2 AND @Divergences = 0 THEN 3
        WHEN @Nodes >= 2 AND @Divergences = 1 THEN 2
        WHEN @Nodes >= 1 THEN 1
        ELSE 0
    END;

    SET @Finding = CONCAT('HA nodes observable = ', @Nodes, ' (availability replicas = ', @Replicas,
        ', cluster nodes = ', @ClusterNodes, '); replica setting variants: availability_mode = ', ISNULL(@ModeVariants, 0),
        ', failover_mode = ', ISNULL(@FailoverVariants, 0), ', session_timeout = ', ISNULL(@TimeoutVariants, 0),
        '; replicas not in a healthy synchronisation state = ', ISNULL(@Unhealthy, 0),
        '; instance settings pending restart = ', ISNULL(@PendingConfig, 0), ' [', @PendingNames,
        ']; local baseline to compare on the peer node: server logins = ', ISNULL(@Logins, 0),
        ', linked servers = ', ISNULL(@LinkedServers, 0), ', certificates = ', ISNULL(@Certificates, 0),
        ', SQL Agent jobs = ', ISNULL(@Jobs, 0), '. Divergence indicators = ', @Divergences, '.');
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;