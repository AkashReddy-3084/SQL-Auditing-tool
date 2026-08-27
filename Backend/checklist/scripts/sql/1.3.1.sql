-- Checklist: HA approach defined and matches SLA (Always On AG / failover cluster / zone-redundant / failover groups)
-- Scope: SERVER
<<<<<<< Updated upstream
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
=======
-- Scoring: 3 = clear HA detected (AGs > 0 OR clustered with multiple nodes); 2 = partial or ambiguous HA evidence (hadr or clustered flag on but counts missing); 1 = minimal evidence (engine indicates PaaS/MI but no HA objects found); 0 = no evidence
-- NOTE: Automated evidence only; full compliance requires human review when the score is below 3.

SET NOCOUNT ON;

DECLARE
@Result nvarchar(10) = 'Fail',
@Score int = 0,
@DatabaseQueried sysname = 'master',
@Finding nvarchar(max) = N'No evidence collected';

-- Variables to hold probe results (nullable if probe fails)
DECLARE @ags int = NULL;
DECLARE @cluster_nodes int = NULL;
DECLARE @hadr_enabled int = NULL;
DECLARE @is_clustered int = NULL;
DECLARE @engine_edition int = NULL;

-- Probe availability groups (may be unavailable on some SKUs)
BEGIN TRY
EXEC sp_executesql
N'SELECT @out = COUNT(*) FROM sys.availability_groups',
N'@out int OUTPUT',
@out = @ags OUTPUT;
END TRY
BEGIN CATCH
SET @ags = NULL;
END CATCH;

-- Probe cluster nodes DMV (may be unavailable or require permissions)
BEGIN TRY
EXEC sp_executesql
N'SELECT @out = COUNT(*) FROM sys.dm_os_cluster_nodes',
N'@out int OUTPUT',
@out = @cluster_nodes OUTPUT;
END TRY
BEGIN CATCH
SET @cluster_nodes = NULL;
END CATCH;

-- Safe SERVERPROPERTY probes
BEGIN TRY
SET @hadr_enabled = CASE WHEN TRY_CAST(SERVERPROPERTY('IsHadrEnabled') AS int) IS NULL THEN NULL ELSE CAST(SERVERPROPERTY('IsHadrEnabled') AS int) END;
SET @is_clustered = CASE WHEN TRY_CAST(SERVERPROPERTY('IsClustered') AS int) IS NULL THEN NULL ELSE CAST(SERVERPROPERTY('IsClustered') AS int) END;
SET @engine_edition = CASE WHEN TRY_CAST(SERVERPROPERTY('EngineEdition') AS int) IS NULL THEN NULL ELSE CAST(SERVERPROPERTY('EngineEdition') AS int) END;
END TRY
BEGIN CATCH
SET @hadr_enabled = NULL;
SET @is_clustered = NULL;
SET @engine_edition = NULL;
END CATCH;

-- Scoring logic:
-- 3 = clear HA: ags > 0 OR (is_clustered = 1 AND cluster_nodes > 1)
-- 2 = partial/ambiguous HA evidence: hadr_enabled = 1 OR is_clustered = 1 or cluster_nodes > 0 but not clearly multi-node
-- 1 = minimal: engine_edition indicates Azure/MI but no HA objects found
-- 0 = none
IF @ags IS NOT NULL AND @ags > 0
SET @Score = 3;
ELSE IF @is_clustered = 1 AND @cluster_nodes IS NOT NULL AND @cluster_nodes > 1
SET @Score = 3;
ELSE IF (@hadr_enabled = 1) OR (@is_clustered = 1) OR (@cluster_nodes IS NOT NULL AND @cluster_nodes > 0)
SET @Score = 2;
ELSE IF @engine_edition IS NOT NULL AND @engine_edition IN (5,8) -- Azure SQL DB (5) or MI (8): platform suggests PaaS HA may be provided
SET @Score = 1;
ELSE
SET @Score = 0;

-- Build Finding from actual values returned
DECLARE @parts TABLE (ord int, txt nvarchar(max));

INSERT INTO @parts VALUES (1, N'ags = ' + ISNULL(CASE WHEN @ags IS NULL THEN N'Unavailable' ELSE CONVERT(nvarchar(20), @ags) END, N'Unavailable'));
INSERT INTO @parts VALUES (2, N'cluster_nodes = ' + ISNULL(CASE WHEN @cluster_nodes IS NULL THEN N'Unavailable' ELSE CONVERT(nvarchar(20), @cluster_nodes) END, N'Unavailable'));
INSERT INTO @parts VALUES (3, N'hadr_enabled = ' + ISNULL(CASE WHEN @hadr_enabled IS NULL THEN N'Unavailable' ELSE CONVERT(nvarchar(20), @hadr_enabled) END, N'Unavailable'));
INSERT INTO @parts VALUES (4, N'is_clustered = ' + ISNULL(CASE WHEN @is_clustered IS NULL THEN N'Unavailable' ELSE CONVERT(nvarchar(20), @is_clustered) END, N'Unavailable'));
INSERT INTO @parts VALUES (5, N'engine_edition = ' + ISNULL(CASE WHEN @engine_edition IS NULL THEN N'Unavailable' ELSE CONVERT(nvarchar(20), @engine_edition) END, N'Unavailable'));

SELECT @Finding = STRING_AGG(txt, '; ') WITHIN GROUP (ORDER BY ord) FROM @parts;

-- Ensure non-empty Finding
IF @Finding IS NULL OR LEN(@Finding) = 0
SET @Finding = N'No evidence returned from probes';

-- Derive Result
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
>>>>>>> Stashed changes
