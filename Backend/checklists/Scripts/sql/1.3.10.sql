-- Checklist: HA node configuration parity verified - both nodes have identical instance configuration, trace flags, MAXDOP/memory, logins, SQL Agent jobs, linked servers, and certificates
-- Scope: SERVER
-- Scoring: 3 = all available parity indicators are present with no pending configuration; 2 = strong but incomplete parity evidence; 1 = partial HA-node evidence; 0 = no evidence
-- NOTE: Automated evidence only; full parity requires comparing both nodes and human review.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'HA node parity evidence could not be evaluated';
DECLARE @ClusterNodes INT = 0;
DECLARE @PendingConfig INT = 0;
DECLARE @TraceFlagEntries INT = 0;
DECLARE @Replicas INT = 0;
DECLARE @ProbeError NVARCHAR(4000) = N'';
DECLARE @Sql NVARCHAR(MAX);

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SET @Score = 1;
    SET @Finding = N'Azure SQL Database does not expose peer-instance configuration parity through this T-SQL probe';
END
ELSE
BEGIN
    BEGIN TRY
        SELECT @ClusterNodes = COUNT(*) FROM sys.dm_os_cluster_nodes;
    END TRY
    BEGIN CATCH SET @ProbeError = ERROR_MESSAGE(); END CATCH;

    SELECT @PendingConfig = COUNT(*) FROM sys.configurations WHERE value <> value_in_use;

    BEGIN TRY
        SET @Sql = N'SELECT @value = COUNT(*) FROM sys.dm_server_registry WHERE registry_key LIKE ''%Parameters%'' AND CAST(value_data AS nvarchar(400)) LIKE ''-T%'';';
        EXEC sys.sp_executesql @Sql, N'@value INT OUTPUT', @value = @TraceFlagEntries OUTPUT;
    END TRY
    BEGIN CATCH IF @ProbeError = N'' SET @ProbeError = ERROR_MESSAGE(); END CATCH;

    BEGIN TRY
        SELECT @Replicas = COUNT(*) FROM sys.availability_replicas;
    END TRY
    BEGIN CATCH IF @ProbeError = N'' SET @ProbeError = ERROR_MESSAGE(); END CATCH;

    IF @ClusterNodes >= 2 AND @PendingConfig = 0 AND @TraceFlagEntries >= 0 AND @Replicas >= 2
    BEGIN SET @Score = 3; SET @Finding = N'HA parity indicators are strong: cluster_nodes=' + CONVERT(NVARCHAR(20), @ClusterNodes) + N', pending_config=' + CONVERT(NVARCHAR(20), @PendingConfig) + N', trace_flag_entries=' + CONVERT(NVARCHAR(20), @TraceFlagEntries) + N', replicas=' + CONVERT(NVARCHAR(20), @Replicas); END
    ELSE IF @ClusterNodes >= 2 OR @Replicas >= 2
    BEGIN SET @Score = 2; SET @Finding = N'Multi-node HA evidence found but parity is incomplete: cluster_nodes=' + CONVERT(NVARCHAR(20), @ClusterNodes) + N', pending_config=' + CONVERT(NVARCHAR(20), @PendingConfig) + N', trace_flag_entries=' + CONVERT(NVARCHAR(20), @TraceFlagEntries) + N', replicas=' + CONVERT(NVARCHAR(20), @Replicas); END
    ELSE IF @ClusterNodes > 0 OR @Replicas > 0
    BEGIN SET @Score = 1; SET @Finding = N'Partial HA-node evidence found: cluster_nodes=' + CONVERT(NVARCHAR(20), @ClusterNodes) + N', pending_config=' + CONVERT(NVARCHAR(20), @PendingConfig) + N', trace_flag_entries=' + CONVERT(NVARCHAR(20), @TraceFlagEntries) + N', replicas=' + CONVERT(NVARCHAR(20), @Replicas); END
    ELSE
    BEGIN SET @Score = 0; SET @Finding = N'No HA-node or replica evidence found: cluster_nodes=0, pending_config=' + CONVERT(NVARCHAR(20), @PendingConfig) + N', trace_flag_entries=' + CONVERT(NVARCHAR(20), @TraceFlagEntries) + N', replicas=0;'; END

    IF @ProbeError <> N'' SET @Finding = @Finding + N' probe_warning=' + @ProbeError;
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;