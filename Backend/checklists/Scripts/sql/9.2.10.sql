-- Checklist: WSFC quorum / witness configured correctly for the node count (avoids split-brain); quorum model documented
-- Scope: SERVER
-- Scoring: 3 = cluster in NORMAL_QUORUM whose voting members (nodes plus any witness) total an odd number; 2 = no WSFC and no availability group so quorum does not apply, or the platform manages quorum (Azure SQL Database / Managed Instance); 1 = cluster present but quorum state is not normal, or an availability group exists with unreadable cluster metadata; 0 = even number of voting members with no witness, or no quorum model configured

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'Cluster quorum evidence could not be collected from this instance';
DECLARE @Edition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Nodes INT = 0;
DECLARE @Groups INT = 0;
DECLARE @QuorumType NVARCHAR(60) = 'unavailable';
DECLARE @QuorumState NVARCHAR(60) = 'unavailable';
DECLARE @ClusterName NVARCHAR(200) = 'none';
DECLARE @Witness INT = 0;
DECLARE @Votes INT = 0;
DECLARE @Note NVARCHAR(300) = '';

IF @Edition = 5 OR OBJECT_ID('sys.dm_os_cluster_nodes') IS NULL
BEGIN
    SET @Score = 2;
    SET @Finding = CONCAT('EngineEdition ', @Edition,
        ': Windows Server Failover Cluster views are not exposed, so no user-configurable quorum or witness exists; quorum and split-brain protection for the replica set are enforced by the platform.');
END
ELSE
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT @n = COUNT(*) FROM sys.dm_os_cluster_nodes;';
        EXEC sp_executesql @Sql, N'@n INT OUTPUT', @n = @Nodes OUTPUT;

        IF OBJECT_ID('sys.dm_os_cluster_properties') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT @c = ISNULL(MAX(cluster_name), ''unknown''),
       @t = ISNULL(MAX(quorum_type_desc), ''unavailable''),
       @s = ISNULL(MAX(quorum_state_desc), ''unavailable'')
FROM sys.dm_os_cluster_properties;';
            EXEC sp_executesql @Sql,
                 N'@c NVARCHAR(200) OUTPUT, @t NVARCHAR(60) OUTPUT, @s NVARCHAR(60) OUTPUT',
                 @c = @ClusterName OUTPUT, @t = @QuorumType OUTPUT, @s = @QuorumState OUTPUT;
        END
    END TRY
    BEGIN CATCH
        SET @Note = ' Cluster node or quorum properties were not readable.';
    END CATCH

    BEGIN TRY
        IF OBJECT_ID('sys.availability_groups') IS NOT NULL
        BEGIN
            SET @Sql = N'SELECT @a = COUNT(*) FROM sys.availability_groups;';
            EXEC sp_executesql @Sql, N'@a INT OUTPUT', @a = @Groups OUTPUT;
        END
    END TRY
    BEGIN CATCH
        SET @Note = @Note + ' Availability group list was not readable.';
    END CATCH

    SET @Nodes = ISNULL(@Nodes, 0);
    SET @Groups = ISNULL(@Groups, 0);
    SET @QuorumType = ISNULL(@QuorumType, 'unavailable');
    SET @QuorumState = ISNULL(@QuorumState, 'unavailable');
    SET @ClusterName = ISNULL(@ClusterName, 'none');

    -- A witness adds one vote: disk, file share and cloud witnesses all report as a NODE_AND_* or DISK_ONLY model.
    SET @Witness = CASE WHEN @QuorumType LIKE '%AND[_]%' OR @QuorumType LIKE '%DISK[_]ONLY%' THEN 1 ELSE 0 END;
    SET @Votes = @Nodes + @Witness;

    SET @Score = CASE
        WHEN @Nodes = 0 AND @Groups = 0 THEN 2
        WHEN @QuorumType = 'unavailable' OR @QuorumType = 'UNKNOWN_QUORUM' THEN 0
        WHEN @QuorumState <> 'NORMAL_QUORUM' THEN 1
        WHEN @Votes % 2 = 1 THEN 3
        ELSE 0 END;

    SET @Finding = CONCAT('Cluster ', @ClusterName, ': nodes = ', @Nodes,
        ', quorum model = ', @QuorumType, ', quorum state = ', @QuorumState,
        ', witness vote counted = ', @Witness, ', total voting members = ', @Votes,
        ', availability groups = ', @Groups, '.',
        CASE WHEN @Nodes = 0 AND @Groups = 0
             THEN ' This is a standalone instance with no failover cluster, so no quorum model applies.'
             WHEN @Votes > 0 AND @Votes % 2 = 0
             THEN ' An even number of voting members with no additional witness leaves the cluster exposed to split-brain.'
             ELSE '' END,
        @Note);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
