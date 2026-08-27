-- Checklist: HA approach defined and matches SLA (Always On AG / failover cluster / zone-redundant / failover groups)
-- Scope: SERVER
-- Scoring: 3 = Always On AG or failover cluster evidence is active; 2 = platform-managed HA or partial HA evidence; 1 = HA capability enabled without active topology; 0 = no HA evidence
-- NOTE: Automated evidence only; confirm that the observed HA approach matches the documented SLA.

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = N'master';
DECLARE @Finding NVARCHAR(MAX) = N'HA metadata could not be evaluated';
DECLARE @EngineEdition INT = ISNULL(CONVERT(INT, SERVERPROPERTY('EngineEdition')), 0);
DECLARE @AgCount INT = 0;
DECLARE @ClusterNodeCount INT = 0;
DECLARE @HadrEnabled INT = ISNULL(CONVERT(INT, SERVERPROPERTY('IsHadrEnabled')), 0);
DECLARE @IsClustered INT = ISNULL(CONVERT(INT, SERVERPROPERTY('IsClustered')), 0);
DECLARE @ProbeError NVARCHAR(4000) = N'';
DECLARE @Sql NVARCHAR(MAX);

IF @EngineEdition = 5
BEGIN
    SET @Score = 2;
    SET @Finding = N'Azure SQL Database: HA is platform-managed; zone redundancy or failover-group configuration is not exposed by this T-SQL probe. '
                 + N'engine_edition=' + CONVERT(NVARCHAR(20), @EngineEdition)
                 + N', hadr_enabled=' + CONVERT(NVARCHAR(20), @HadrEnabled)
                 + N', is_clustered=' + CONVERT(NVARCHAR(20), @IsClustered);
END
ELSE
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT @value = COUNT(*) FROM sys.availability_groups;';
        EXEC sys.sp_executesql @Sql, N'@value INT OUTPUT', @value = @AgCount OUTPUT;
    END TRY
    BEGIN CATCH
        SET @ProbeError = ERROR_MESSAGE();
    END CATCH;

    BEGIN TRY
        SET @Sql = N'SELECT @value = COUNT(*) FROM sys.dm_os_cluster_nodes;';
        EXEC sys.sp_executesql @Sql, N'@value INT OUTPUT', @value = @ClusterNodeCount OUTPUT;
    END TRY
    BEGIN CATCH
        IF @ProbeError = N'' SET @ProbeError = ERROR_MESSAGE();
    END CATCH;

    IF @AgCount > 0 AND @HadrEnabled = 1
    BEGIN
        SET @Score = 3;
        SET @Finding = N'Always On availability group evidence found: ags='
                     + CONVERT(NVARCHAR(20), @AgCount) + N', cluster_nodes='
                     + CONVERT(NVARCHAR(20), @ClusterNodeCount) + N', hadr_enabled='
                     + CONVERT(NVARCHAR(20), @HadrEnabled) + N', is_clustered='
                     + CONVERT(NVARCHAR(20), @IsClustered);
    END
    ELSE IF @IsClustered = 1 AND @ClusterNodeCount > 1
    BEGIN
        SET @Score = 3;
        SET @Finding = N'Failover cluster evidence found: ags='
                     + CONVERT(NVARCHAR(20), @AgCount) + N', cluster_nodes='
                     + CONVERT(NVARCHAR(20), @ClusterNodeCount) + N', hadr_enabled='
                     + CONVERT(NVARCHAR(20), @HadrEnabled) + N', is_clustered='
                     + CONVERT(NVARCHAR(20), @IsClustered);
    END
    ELSE IF @HadrEnabled = 1 OR @IsClustered = 1 OR @AgCount > 0 OR @ClusterNodeCount > 0
    BEGIN
        SET @Score = 1;
        SET @Finding = N'Partial HA evidence found: ags='
                     + CONVERT(NVARCHAR(20), @AgCount) + N', cluster_nodes='
                     + CONVERT(NVARCHAR(20), @ClusterNodeCount) + N', hadr_enabled='
                     + CONVERT(NVARCHAR(20), @HadrEnabled) + N', is_clustered='
                     + CONVERT(NVARCHAR(20), @IsClustered);
    END
    ELSE
    BEGIN
        SET @Score = 0;
        SET @Finding = N'No active Always On availability group or failover cluster evidence found: ags='
                     + CONVERT(NVARCHAR(20), @AgCount) + N', cluster_nodes='
                     + CONVERT(NVARCHAR(20), @ClusterNodeCount) + N', hadr_enabled='
                     + CONVERT(NVARCHAR(20), @HadrEnabled) + N', is_clustered='
                     + CONVERT(NVARCHAR(20), @IsClustered);
    END;

    IF @ProbeError <> N''
        SET @Finding = @Finding + N'; probe_warning=' + @ProbeError;
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;